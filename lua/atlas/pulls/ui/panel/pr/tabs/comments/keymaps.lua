local M = {}

local help = require("atlas.ui.popups.help")
local layout = require("atlas.ui.layout")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function from_action(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local tab = require("atlas.pulls.ui.panel.pr.tabs.comments")
	local panel_state = require("atlas.pulls.ui.panel.pr.state")

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
				local pr = panel_state.current_pr
				if pr then
					tab.add_comment(pr, refresh)
				end
			end,
		},
		{
			key = "c",
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.reply_comment(pr, entry, refresh)
				end
			end,
		},
		{
			key = "e",
			desc = "Edit comment/task",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.edit_comment(pr, entry, refresh)
				end
			end,
		},
		{
			key = "d",
			desc = "Delete comment/task",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.delete_comment(pr, entry, refresh)
				end
			end,
		},
		{
			key = "T",
			desc = "Add task",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr then
					tab.add_task(pr, refresh)
				end
			end,
		},
		{
			key = "t",
			desc = "Toggle task resolved",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.toggle_task(pr, entry, refresh)
				end
			end,
		},
	}

	utils.insert_if(items, from_action("ui.toggle_fold", {
		desc = "Toggle hunk fold",
		opts = { nowait = true, silent = true },
		callback = function()
			local state = require("atlas.pulls.ui.panel.pr.tabs.comments.state")
			local entry = cursor_entry()
			if entry == nil then
				return
			end
			local key = entry.hunk_key
			if key == nil then
				local win = layout.win_id("detail")
				local panel_state2 = require("atlas.pulls.ui.panel.pr.state")
				local lnum = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1] or 0
				local map = panel_state2.line_map or {}
				for ln = lnum, 1, -1 do
					local e = map[ln]
					if e and e.kind == "hunk_header" and e.hunk_key then
						key = e.hunk_key
						break
					end
				end
			end
			if key ~= nil then
				state.collapsed_hunks[key] = not (state.collapsed_hunks[key] == true)
				refresh()
			end
		end,
	}))
	utils.insert_if(items, from_action("ui.toggle_all_folds", {
		desc = "Toggle all hunk folds",
		opts = { nowait = true, silent = true },
		callback = function()
			local state = require("atlas.pulls.ui.panel.pr.tabs.comments.state")
			local comments = state.comments
			if type(comments) ~= "table" then
				return
			end
			local keys = {}
			for _, c in ipairs(comments) do
				if c.inline and c.inline_hunk then
					local h = c.inline_hunk
					table.insert(
						keys,
						string.format("%s|%s|%s", c.inline.path, tostring(h.new_start or 0), tostring(h.old_start or 0))
					)
				end
			end
			if #keys == 0 then
				return
			end
			local any_open = false
			for _, k in ipairs(keys) do
				if state.collapsed_hunks[k] ~= true then
					any_open = true
					break
				end
			end
			for _, k in ipairs(keys) do
				state.collapsed_hunks[k] = any_open
			end
			refresh()
		end,
	}))
	utils.insert_if(items, from_action("pulls.next_hunk", {
		desc = "Next hunk",
		opts = { nowait = true, silent = true },
		callback = function()
			local win = layout.win_id("detail")
			if win == nil or not vim.api.nvim_win_is_valid(win) then
				return
			end
			local panel_state2 = require("atlas.pulls.ui.panel.pr.state")
			local map = panel_state2.line_map or {}
			local lnum = vim.api.nvim_win_get_cursor(win)[1]
			local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
			for ln = lnum + 1, last do
				local e = map[ln]
				if e and e.kind == "hunk_header" then
					pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
					return
				end
			end
		end,
	}))
	utils.insert_if(items, from_action("pulls.previous_hunk", {
		desc = "Previous hunk",
		opts = { nowait = true, silent = true },
		callback = function()
			local win = layout.win_id("detail")
			if win == nil or not vim.api.nvim_win_is_valid(win) then
				return
			end
			local panel_state2 = require("atlas.pulls.ui.panel.pr.state")
			local map = panel_state2.line_map or {}
			local lnum = vim.api.nvim_win_get_cursor(win)[1]
			for ln = lnum - 1, 1, -1 do
				local e = map[ln]
				if e and e.kind == "hunk_header" then
					pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
					return
				end
			end
		end,
	}))

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@param buf integer
function M.teardown(buf)
	local items = {
		{ key = "a" },
		{ key = "i" },
		{ key = "c" },
		{ key = "e" },
		{ key = "d" },
		{ key = "T" },
		{ key = "t" },
	}
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	utils.insert_if(items, remove_item("ui.toggle_all_folds"))
	utils.insert_if(items, remove_item("pulls.next_hunk"))
	utils.insert_if(items, remove_item("pulls.previous_hunk"))
	help.remove("Panel", items, { buffer = buf })
end

return M
