local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local layout = require("atlas.ui.layout")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
local actions = require("atlas.pulls.ui.panel.pr.tabs.conversation.actions")

local COMMENT_ACTIONS = {
	"ui.comments.add",
	"ui.comments.reply",
	"ui.comments.edit",
	"ui.delete",
	"ui.comments.react",
}

local function cursor_entry()
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return (panel_state.line_map or {})[lnum]
end

---@param refresh fun()
---@param fn fun(pr: PullRequest, refresh: fun())
local function dispatch_simple(refresh, fn)
	local pr = panel_state.current_details or panel_state.current_pr
	if pr == nil then
		return
	end
	fn(pr, refresh)
end

---@param refresh fun()
---@param fn fun(pr: PullRequest, entry: table, refresh: fun())
local function dispatch_with_entry(refresh, fn)
	local pr = panel_state.current_details or panel_state.current_pr
	if pr == nil then
		return
	end
	local entry = cursor_entry()
	if not entry then
		return
	end
	fn(pr, entry, refresh)
end

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function from_action(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	map_item.key = #keys == 1 and keys[1] or keys
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
	local provider = require("atlas.pulls.state").provider
	local tasks = provider and provider.capabilities.tasks
	local has_tasks = tasks and tasks.edit_task ~= nil
	local items = {}
	utils.insert_if(
		items,
		from_action("ui.comments.add", {
			desc = "Add comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_simple(refresh, actions.add)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.reply", {
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.reply)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.edit", {
			desc = has_tasks and "Edit comment / task" or "Edit comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.edit)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.delete", {
			desc = has_tasks and "Delete comment / task" or "Delete comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.delete)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.react", {
			desc = "Add reaction",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.react)
			end,
		})
	)
	if has_tasks then
		local toggle_task = from_action("pulls.review.diff.toggle_resolved", {
			desc = "Toggle task",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.toggle_task)
			end,
		})
		if toggle_task then
			table.insert(items, toggle_task)
		end
	end
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, {
			key = fold_keys,
			desc = "Expand / collapse comment or thread",
			opts = { nowait = true, silent = true },
			callback = function()
				toggle_fold(refresh)
			end,
		})
	end
	local toggle_all = from_action("ui.toggle_all_folds", {
		desc = "Expand / collapse all threads",
		opts = { nowait = true, silent = true },
		callback = function()
			local comments = state.comments(false)
			local task_comments = state.comments(true)
			if state.toggle_all_threads(review_threads.group_comments(comments, task_comments)) then
				refresh()
			end
		end,
	})
	if toggle_all then
		table.insert(items, toggle_all)
	end
	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action_id in ipairs(COMMENT_ACTIONS) do
		utils.insert_if(items, from_action(action_id, {}))
	end
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, { key = fold_keys })
	end
	local toggle_all_keys = resolver.resolve("ui.toggle_all_folds")
	if toggle_all_keys ~= nil then
		table.insert(items, { key = #toggle_all_keys == 1 and toggle_all_keys[1] or toggle_all_keys })
	end
	local provider = require("atlas.pulls.state").provider
	local tasks = provider and provider.capabilities.tasks
	if tasks and tasks.edit_task then
		local toggle_task_keys = resolver.resolve("pulls.review.diff.toggle_resolved")
		if toggle_task_keys ~= nil then
			table.insert(items, { key = #toggle_task_keys == 1 and toggle_task_keys[1] or toggle_task_keys })
		end
	end
	help.remove("Panel", items, { buffer = buf })
end

return M
