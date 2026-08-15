local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local layout = require("atlas.ui.layout")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
local actions = require("atlas.issues.ui.panel.issue.tabs.conversation.actions")

local function cursor_entry()
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return (panel_state.line_map or {})[lnum]
end

---@param refresh fun()
---@param fn fun(issue: Issue, refresh: fun())
local function dispatch_simple(refresh, fn)
	local issue = panel_state.current_issue
	if issue == nil then
		return
	end
	fn(issue, refresh)
end

---@param refresh fun()
---@param fn fun(issue: Issue, entry: table, refresh: fun())
local function dispatch_with_entry(refresh, fn)
	local issue = panel_state.current_issue
	if issue == nil then
		return
	end
	local entry = cursor_entry()
	if not entry then
		return
	end
	fn(issue, entry, refresh)
end

---@param refresh fun()
local function toggle_thread(refresh)
	local entry = cursor_entry()
	if not entry then
		return
	end
	if entry.run_id ~= nil then
		state.toggle_run(entry.run_id)
		refresh()
		return
	end
	local root = entry.thread_root or entry.comment
	if not root then
		return
	end
	state.toggle(root.id)
	refresh()
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local items = {
		{
			key = { "a", "i" },
			desc = "Add comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_simple(refresh, actions.add)
			end,
		},
		{
			key = "c",
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.reply)
			end,
		},
		{
			key = "e",
			desc = "Edit comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.edit)
			end,
		},
		{
			key = "d",
			desc = "Delete comment",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.delete)
			end,
		},
		{
			key = "gr",
			desc = "Add reaction",
			opts = { nowait = true, silent = true },
			callback = function()
				dispatch_with_entry(refresh, actions.react)
			end,
		},
	}

	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, {
			key = fold_keys,
			desc = "Expand / collapse thread",
			opts = { nowait = true, silent = true },
			callback = function()
				toggle_thread(refresh)
			end,
		})
	end

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {
		{ key = { "a", "i" } },
		{ key = "c" },
		{ key = "e" },
		{ key = "d" },
		{ key = "gr" },
	}
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, { key = fold_keys })
	end
	help.remove("Panel", items, { buffer = buf })
end

return M
