local M = {}

local help = require("atlas.ui.popups.help")
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
	local tab = require("atlas.pulls.ui.detail.tabs.review")
	local detail = require("atlas.pulls.ui.detail.state")
	local provider = detail.provider
	local tasks = provider and provider.capabilities.tasks
	local edit_description = tasks and tasks.edit_task and "Edit comment / task" or "Edit comment"
	local delete_description = tasks and tasks.delete_task and "Delete comment / task" or "Delete comment"

	local function cursor_entry()
		local win = detail.win
		if win == nil or not vim.api.nvim_win_is_valid(win) then
			return nil
		end
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		return (detail.line_map or {})[lnum]
	end

	local items = {}
	utils.insert_if(
		items,
		from_action("ui.comments.reply", {
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_details or detail.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.reply_comment(pr, entry, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.comments.edit", {
			desc = edit_description,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_details or detail.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.edit_comment(pr, entry, refresh)
				end
			end,
		})
	)
	if tasks and tasks.add_task then
		utils.insert_if(
			items,
			from_action("pulls.review.add_task", {
				desc = "Add task",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = detail.current_details or detail.current_pr
					if pr then
						tab.add_task(pr, refresh)
					end
				end,
			})
		)
	end
	utils.insert_if(
		items,
		from_action("ui.delete", {
			desc = delete_description,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_details or detail.current_pr
				local entry = cursor_entry()
				if pr and entry then
					tab.delete_comment(pr, entry, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("pulls.review.diff.toggle_resolved", {
			desc = "Toggle resolved",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_details or detail.current_pr
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
				tab.show_details(cursor_entry(), buf)
			end,
		})
	)

	utils.insert_if(
		items,
		from_action("ui.toggle_fold", {
			desc = "Toggle thread fold",
			opts = { nowait = true, silent = true },
			callback = function()
				local state = require("atlas.pulls.ui.detail.tabs.review.state")
				local entry = cursor_entry()
				if entry == nil then
					return
				end

				local entity = entry.entity_kind
				if entity == "comment" or entity == "task" then
					local roots = entry.thread_roots or (entry.thread_root and { entry.thread_root }) or {}
					if state.toggle_threads(roots) then
						refresh()
						return
					end
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.toggle_all_folds", {
			desc = "Toggle all thread folds",
			opts = { nowait = true, silent = true },
			callback = function()
				local state = require("atlas.pulls.ui.detail.tabs.review.state")
				local data = state.data
				if not data then
					return
				end
				if state.toggle_all_folds(data.comments) then
					refresh()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("pulls.review.diff.next_hunk", {
			desc = "Next hunk",
			opts = { nowait = true, silent = true },
			callback = function()
				local win = detail.win
				if win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local map = detail.line_map or {}
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
				for ln = lnum + 1, last do
					local e = map[ln]
					if e and e.hunk_start then
						pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
						return
					end
				end
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("pulls.review.diff.previous_hunk", {
			desc = "Previous hunk",
			opts = { nowait = true, silent = true },
			callback = function()
				local win = detail.win
				if win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local map = detail.line_map or {}
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				for ln = lnum - 1, 1, -1 do
					local e = map[ln]
					if e and e.hunk_start then
						pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
						return
					end
				end
			end,
		})
	)

	help.register("Detail", items, { index = 212, buffer = buf })
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
	local items = {}
	utils.insert_if(items, remove_item("ui.comments.reply"))
	utils.insert_if(items, remove_item("ui.comments.edit"))
	utils.insert_if(items, remove_item("pulls.review.add_task"))
	utils.insert_if(items, remove_item("ui.delete"))
	utils.insert_if(items, remove_item("pulls.review.diff.toggle_resolved"))
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	utils.insert_if(items, remove_item("ui.toggle_all_folds"))
	utils.insert_if(items, remove_item("pulls.review.diff.next_hunk"))
	utils.insert_if(items, remove_item("pulls.review.diff.previous_hunk"))
	utils.insert_if(items, remove_item("ui.show_details"))
	help.remove("Detail", items, { buffer = buf })
end

return M
