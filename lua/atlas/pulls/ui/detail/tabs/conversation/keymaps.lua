local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local detail = require("atlas.pulls.ui.detail.state")
local review_actions = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local actions = require("atlas.pulls.ui.detail.tabs.conversation.actions")

local registrations = {}

local function cursor_entry()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return detail.line_map[lnum]
end

---@param refresh fun()
---@param fn fun(pr: PullRequest, refresh: fun())
local function dispatch_simple(refresh, fn)
	local pr = detail.current_pr
	if pr == nil then
		return
	end
	fn(pr, refresh)
end

---@param refresh fun()
---@param fn fun(pr: PullRequest, entry: table, refresh: fun())
local function dispatch_with_entry(refresh, fn)
	local pr = detail.current_pr
	if pr == nil then
		return
	end
	local entry = cursor_entry()
	if not entry then
		return
	end
	fn(pr, entry, refresh)
end

---@param action_id AtlasKeymapActionId
---@param map_item table
---@return table|nil
local function from_action(action_id, map_item)
	local keymap = resolver.resolve(action_id)
	if keymap == nil then
		return nil
	end
	map_item.key = keymap.key
	map_item.desc = keymap.desc
	return map_item
end

---@param refresh fun()
local function toggle_fold(refresh)
	local entry = cursor_entry()
	if not entry then
		return
	end
	if entry.run_id ~= nil then
		state.toggle_run(entry.run_id)
		refresh()
		return
	end

	local comment = entry.comment
	local kind = tostring(entry.kind or "")
	local content_line = kind:find("content", 1, true) ~= nil
	local standalone_root = entry.thread_has_replies ~= true
	if comment and (content_line or standalone_root) and state.toggle_comment(comment) then
		refresh()
		return
	end

	local root = entry.thread_root or entry.comment
	if not root then
		return
	end
	if root.is_task or entry.thread_has_replies ~= true then
		return
	end
	state.toggle(root.id)
	refresh()
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local provider = detail.provider
	local tasks = provider and provider.capabilities.tasks
	local has_tasks = tasks and tasks.edit_task ~= nil
	local can_react = provider and provider.capabilities.comments and provider.capabilities.comments.reactions ~= nil
	local items = {}
	utils.insert_if(
		items,
		from_action("ui.comments.add", {
			index = 20,
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_simple(refresh, actions.add)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.reply", {
			index = 21,
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.reply)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.edit", {
			index = 30,
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.edit)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.delete", {
			index = 41,
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.delete)
			end,
		})
	)
	if can_react then
		utils.insert_if(
			items,
			from_action("ui.comments.react", {
				index = 22,
				opts = { nowait = true, silent = true },
				callback = function()
					dispatch_with_entry(refresh, actions.react)
				end,
			})
		)
	end
	if has_tasks then
		local toggle_task = from_action("pulls.review.toggle_resolved", {
			index = 40,
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.toggle_task)
			end,
		})
		if toggle_task then
			table.insert(items, toggle_task)
		end
	end
	local fold = from_action("ui.toggle_fold", {
		index = 10,
		opts = { nowait = true, silent = true },
		callback = function()
			toggle_fold(refresh)
		end,
	})
	if fold then
		table.insert(items, fold)
	end
	local toggle_all = from_action("ui.toggle_all_folds", {
		index = 11,
		opts = { nowait = true, silent = true },
		callback = function()
			local comments = state.comments(false)
			local task_comments = state.comments(true)
			if state.toggle_all_threads(review_actions.group_comments(comments, task_comments)) then
				refresh()
			end
		end,
	})
	if toggle_all then
		table.insert(items, toggle_all)
	end
	M.teardown(buf)
	help.register("Detail", items, { index = 2, buffer = buf })
	registrations[buf] = items
end

---@param buf integer
function M.teardown(buf)
	local registered = registrations[buf]
	if registered then
		help.remove("Detail", registered, { buffer = buf })
		registrations[buf] = nil
	end
end

return M
