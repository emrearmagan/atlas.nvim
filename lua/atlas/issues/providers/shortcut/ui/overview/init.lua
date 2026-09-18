local M = {}

local activity = require("atlas.issues.ui.detail.tabs.activity")
local detail = require("atlas.issues.ui.detail.state")
local editor = require("atlas.ui.popups.editor")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local overview = require("atlas.issues.ui.detail.tabs.overview")
local tasks = require("atlas.issues.providers.shortcut.api.tasks")
local utils = require("atlas.ui.shared.utils")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local ACTIONS = {
	"ui.comments.add",
	"ui.comments.edit",
	"ui.delete",
	"issues.toggle_task",
}

---@return ShortcutIssueTask|nil
local function current_task()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local entry = detail.line_map[vim.api.nvim_win_get_cursor(win)[1]]
	return entry and entry.shortcut_task or nil
end

---@param issue Issue
---@return ShortcutIssueDetails|nil
local function current_details(issue)
	local selected = detail.current_issue
	if selected == nil or tostring(selected.key) ~= tostring(issue.key) then
		return nil
	end
	local details = detail.current_details
	---@cast details ShortcutIssueDetails|nil
	return details
end

---@param details ShortcutIssueDetails
---@param task ShortcutIssueTask
local function upsert_task(details, task)
	for index, existing in ipairs(details.tasks) do
		if existing.id == task.id then
			details.tasks[index] = task
			return
		end
	end
	table.insert(details.tasks, task)
	table.sort(details.tasks, function(a, b)
		return a.position < b.position
	end)
end

---@param details ShortcutIssueDetails
---@param task ShortcutIssueTask
local function remove_task(details, task)
	for index, existing in ipairs(details.tasks) do
		if existing.id == task.id then
			table.remove(details.tasks, index)
			return
		end
	end
end

---@param issue Issue
---@param refresh fun()
local function add_task(issue, refresh)
	editor.open({
		key = "shortcut-checklist-add-" .. tostring(issue.key),
		title = " Add Checklist Item ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end
			notify.loading("Adding Checklist item...")
			tasks.create(issue, text, function(created, err)
				local details = current_details(issue)
				if details == nil then
					return
				end
				if err then
					notify.error("Add Checklist item failed: " .. err)
					return
				end
				if created then
					upsert_task(details, created)
				end
				activity.reset()
				notify.success("Checklist item added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param task ShortcutIssueTask
---@param refresh fun()
local function edit_task(issue, task, refresh)
	editor.open({
		key = "shortcut-checklist-edit-" .. tostring(task.id),
		title = " Edit Checklist Item ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = task.description,
		on_save = function(text)
			if vim.trim(text) == "" or text == task.description then
				return
			end
			notify.loading("Editing Checklist item...")
			tasks.update(issue, task, { description = text }, function(updated, err)
				local details = current_details(issue)
				if details == nil then
					return
				end
				if err then
					notify.error("Edit Checklist item failed: " .. err)
					return
				end
				if updated then
					upsert_task(details, updated)
				end
				activity.reset()
				notify.success("Checklist item updated", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param task ShortcutIssueTask
---@param refresh fun()
local function toggle_task(issue, task, refresh)
	local complete = not task.complete
	notify.loading(complete and "Completing Checklist item..." or "Reopening Checklist item...")
	tasks.update(issue, task, { complete = complete }, function(updated, err)
		local details = current_details(issue)
		if details == nil then
			return
		end
		if err then
			notify.error("Toggle Checklist item failed: " .. err)
			return
		end
		if updated then
			upsert_task(details, updated)
		end
		activity.reset()
		notify.success(complete and "Checklist item completed" or "Checklist item reopened", { timeout = 1200 })
		refresh()
	end)
end

---@param issue Issue
---@param task ShortcutIssueTask
---@param refresh fun()
local function delete_task(issue, task, refresh)
	vim.ui.input({ prompt = "Delete Checklist item? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify.loading("Deleting Checklist item...")
		tasks.delete(issue, task, function(_, err)
			local details = current_details(issue)
			if details == nil then
				return
			end
			if err then
				notify.error("Delete Checklist item failed: " .. err)
				return
			end
			remove_task(details, task)
			activity.reset()
			notify.success("Checklist item deleted", { timeout = 1200 })
			refresh()
		end)
	end)
end

---@param issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(issue, details, width)
	local lines, spans, line_map = overview.render(issue, details, width)
	if details == nil then
		return lines, spans, line_map
	end
	---@cast details ShortcutIssueDetails
	if #details.tasks == 0 then
		return lines, spans, line_map
	end

	table.insert(lines, "")
	utils.push(lines, spans, "Checklist", "AtlasColumnHeader", PADDING_X)
	for _, task in ipairs(details.tasks) do
		local rows = utils.sanitize_lines(task.description)
		local marker = task.complete and "- [x] " or "- [ ] "
		table.insert(lines, PADDING .. marker .. (rows[1] or ""))
		line_map[#lines] = { shortcut_task = task }
		for index = 2, #rows do
			table.insert(lines, PADDING .. "      " .. rows[index])
		end
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.shortcut_task ~= nil
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	overview.activate(buf, refresh)

	local items = {}
	local function add_keymap(action_id, desc, callback)
		local keys = keymaps.resolve(action_id)
		if keys then
			table.insert(items, {
				key = #keys == 1 and keys[1] or keys,
				desc = desc,
				opts = { nowait = true, silent = true },
				callback = callback,
			})
		end
	end

	add_keymap("ui.comments.add", "Add Checklist item", function()
		local issue = detail.current_issue
		if issue and current_details(issue) then
			add_task(issue, refresh)
		end
	end)
	add_keymap("ui.comments.edit", "Edit Checklist item", function()
		local issue = detail.current_issue
		local task = current_task()
		if issue and task then
			edit_task(issue, task, refresh)
		end
	end)
	add_keymap("ui.delete", "Delete Checklist item", function()
		local issue = detail.current_issue
		local task = current_task()
		if issue and task then
			delete_task(issue, task, refresh)
		end
	end)
	add_keymap("issues.toggle_task", "Toggle Checklist item", function()
		local issue = detail.current_issue
		local task = current_task()
		if issue and task then
			toggle_task(issue, task, refresh)
		end
	end)

	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.deactivate(buf)
	local items = {}
	for _, action_id in ipairs(ACTIONS) do
		local keys = keymaps.resolve(action_id)
		if keys then
			table.insert(items, { key = #keys == 1 and keys[1] or keys })
		end
	end
	help.remove("Detail", items, { buffer = buf })
	overview.deactivate(buf)
end

return M
