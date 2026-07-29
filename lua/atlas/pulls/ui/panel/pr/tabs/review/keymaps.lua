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
	local tab = require("atlas.pulls.ui.panel.pr.tabs.review")
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local provider = require("atlas.pulls.state").provider
	local edit_description = provider and provider.edit_task and "Edit comment / task" or "Edit comment"
	local delete_description = provider and provider.delete_task and "Delete comment / task" or "Delete comment"

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
			desc = edit_description,
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
			desc = delete_description,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.delete_comment(pr, entry, refresh)
				end
			end,
		},
	}
	if provider and provider.add_task then
		table.insert(items, {
			key = "T",
			desc = "Add task",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr then
					tab.add_task(pr, refresh)
				end
			end,
		})
	end
	utils.insert_if(
		items,
		from_action("pulls.review.toggle_resolved", {
			desc = "Toggle resolved",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.toggle_resolved(pr, entry, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.show_details", {
			desc = "Show details",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr then
					tab.show_details(pr, cursor_entry(), buf)
				end
			end,
		})
	)

	utils.insert_if(
		items,
		from_action("ui.toggle_fold", {
			desc = "Toggle hunk / thread fold",
			opts = { nowait = true, silent = true },
			callback = function()
				local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
				local entry = cursor_entry()
				if entry == nil then
					return
				end

				local entity = entry.entity_kind
				if entity == "comment" or entity == "comment_summary" or entity == "task" then
					local roots = entry.thread_roots or (entry.thread_root and { entry.thread_root }) or {}
					if state.toggle_threads(roots) then
						refresh()
						return
					end
				end

				local key = entry.hunk_key
				if key == nil then
					local win = layout.win_id("detail")
					local lnum = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1] or 0
					local map = panel_state.line_map or {}
					for ln = lnum, 1, -1 do
						local candidate = map[ln]
						if candidate and candidate.kind == "hunk_header" and candidate.hunk_key then
							key = candidate.hunk_key
							break
						end
					end
				end
				if key ~= nil then
					state.collapsed_hunks[key] = state.collapsed_hunks[key] ~= true
					refresh()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.toggle_all_folds", {
			desc = "Toggle all hunk / thread folds",
			opts = { nowait = true, silent = true },
			callback = function()
				local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
				local comments = state.comments
				if type(comments) ~= "table" then
					return
				end
				local keys = {}
				local seen = {}
				for _, comment in ipairs(comments) do
					if comment.inline and comment.inline.path and comment.inline_hunk then
						local key = string.format(
							"%s|%s|%s",
							comment.inline.path,
							tostring(comment.inline_hunk.new_start or 0),
							tostring(comment.inline_hunk.old_start or 0)
						)
						if not seen[key] then
							seen[key] = true
							table.insert(keys, key)
						end
					end
				end
				if state.toggle_all_folds(comments, keys) then
					refresh()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("pulls.review.next_hunk", {
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
		})
	)
	utils.insert_if(
		items,
		from_action("pulls.review.previous_hunk", {
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
		})
	)

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
		{ key = "c" },
		{ key = "e" },
		{ key = "d" },
		{ key = "T" },
	}
	utils.insert_if(items, remove_item("pulls.review.toggle_resolved"))
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	utils.insert_if(items, remove_item("ui.toggle_all_folds"))
	utils.insert_if(items, remove_item("pulls.review.next_hunk"))
	utils.insert_if(items, remove_item("pulls.review.previous_hunk"))
	utils.insert_if(items, remove_item("ui.show_details"))
	help.remove("Panel", items, { buffer = buf })
end

return M
