local M = {}

local help = require("atlas.ui.popups.help")
local layout = require("atlas.ui.layout")

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local tab = require("atlas.issues.providers.github.ui.conversation")
	local panel_state = require("atlas.issues.ui.panel.issue.state")

	local function cursor_entry()
		local win = layout.win_id("detail")
		if win == nil or not vim.api.nvim_win_is_valid(win) then
			return nil
		end
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		return (panel_state.line_map or {})[lnum]
	end

	local items = {
		{
			key = { "a", "i" },
			desc = "Add comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_issue
				if issue then
					tab.add_comment(issue, refresh)
				end
			end,
		},
		{
			key = "c",
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_issue
				local entry = cursor_entry()
				if issue and entry then
					tab.reply_comment(issue, entry, refresh)
				end
			end,
		},
		{
			key = "e",
			desc = "Edit comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_issue
				local entry = cursor_entry()
				if issue and entry then
					tab.edit_comment(issue, entry, refresh)
				end
			end,
		},
		{
			key = "d",
			desc = "Delete comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_issue
				local entry = cursor_entry()
				if issue and entry then
					tab.delete_comment(issue, entry, refresh)
				end
			end,
		},
		{
			key = "gr",
			desc = "Add reaction",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_issue
				local entry = cursor_entry()
				if issue and entry then
					tab.add_reaction(issue, entry, refresh)
				end
			end,
		},
	}

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	help.remove("Panel", {
		{ key = "a" },
		{ key = "i" },
		{ key = "c" },
		{ key = "e" },
		{ key = "d" },
		{ key = "gr" },
	}, { buffer = buf })
end

return M
