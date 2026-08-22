local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local layout = require("atlas.ui.layout")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
local actions = require("atlas.issues.ui.panel.issue.tabs.conversation.actions")

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
---@param fn fun(issue: IssueDetails, refresh: fun())
local function dispatch_simple(refresh, fn)
	local issue = panel_state.current_details
	if issue then
		fn(issue, refresh)
	end
end

---@param refresh fun()
---@param fn fun(issue: IssueDetails, entry: table, refresh: fun())
local function dispatch_with_entry(refresh, fn)
	local issue = panel_state.current_details
	local entry = cursor_entry()
	if issue and entry then
		fn(issue, entry, refresh)
	end
end

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function from_action(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local item = vim.tbl_deep_extend("force", {}, map_item)
	item.key = #keys == 1 and keys[1] or keys
	return item
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

	local root = entry.thread_root or comment
	if root and entry.thread_has_replies == true then
		state.toggle(root.id)
		refresh()
	end
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local provider = require("atlas.issues.state").provider
	local core = provider and provider.capabilities.core
	local comments = provider and provider.capabilities.comments
	local items = {}

	if comments and comments.add_comment then
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
	end
	if (comments and comments.edit_comment) or (core and core.update_description) then
		utils.insert_if(
			items,
			from_action("ui.comments.edit", {
				desc = "Edit comment",
				opts = { nowait = true, silent = true },
				callback = function()
					dispatch_with_entry(refresh, actions.edit)
				end,
			})
		)
	end
	if comments and comments.delete_comment then
		utils.insert_if(
			items,
			from_action("ui.delete", {
				desc = "Delete comment",
				opts = { nowait = true, silent = true },
				callback = function()
					dispatch_with_entry(refresh, actions.delete)
				end,
			})
		)
	end
	if comments and comments.add_reaction and #(comments.reaction_options or {}) > 0 then
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
	end

	utils.insert_if(
		items,
		from_action("ui.toggle_fold", {
			desc = "Expand / collapse comment or thread",
			opts = { nowait = true, silent = true },
			callback = function()
				toggle_fold(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		from_action("ui.toggle_all_folds", {
			desc = "Expand / collapse all threads",
			opts = { nowait = true, silent = true },
			callback = function()
				if state.toggle_all_threads(comment_threads.group_comments(state.comments())) then
					refresh()
				end
			end,
		})
	)

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action_id in ipairs(COMMENT_ACTIONS) do
		utils.insert_if(items, from_action(action_id, {}))
	end
	utils.insert_if(items, from_action("ui.toggle_fold", {}))
	utils.insert_if(items, from_action("ui.toggle_all_folds", {}))
	help.remove("Panel", items, { buffer = buf })
end

return M
