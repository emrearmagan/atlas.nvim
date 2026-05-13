local M = {}

---@class AtlasUIKeymaps
---@field help? AtlasKeymapValue
---@field close? AtlasKeymapValue
---@field toggle_panel? AtlasKeymapValue
---@field toggle_fold? AtlasKeymapValue
---@field toggle_all_folds? AtlasKeymapValue
---@field previous_panel_tab? AtlasKeymapValue
---@field next_panel_tab? AtlasKeymapValue
---@field open_notifications? AtlasKeymapValue
---@field notifications_mark_read? AtlasKeymapValue
---@field notifications_mark_done? AtlasKeymapValue
---@field notifications_refresh? AtlasKeymapValue
---@field toggle_subscription? AtlasKeymapValue
---@field refresh? AtlasKeymapValue
---@field refresh_view? AtlasKeymapValue
---@field open_actions? AtlasKeymapValue
---@field open_in_browser? AtlasKeymapValue
---@field copy_url? AtlasKeymapValue
---@field show_details? AtlasKeymapValue
---@field search? AtlasKeymapValue

---@class AtlasPullsKeymaps
---@field copy_id? AtlasKeymapValue
---@field open_diff? AtlasKeymapValue
---@field checkout? AtlasKeymapValue
---@field next_hunk? AtlasKeymapValue
---@field previous_hunk? AtlasKeymapValue
---@field filter_status_open? AtlasKeymapValue
---@field filter_status_merged? AtlasKeymapValue
---@field filter_status_declined? AtlasKeymapValue

---@class AtlasIssuesKeymaps
---@field copy_key? AtlasKeymapValue
---@field transition_issue? AtlasKeymapValue
---@field change_assignee? AtlasKeymapValue
---@field change_reporter? AtlasKeymapValue
---@field edit_issue? AtlasKeymapValue
---@field create_issue? AtlasKeymapValue

---@class AtlasKeymapsConfig
---@field ui? AtlasUIKeymaps
---@field pulls? AtlasPullsKeymaps
---@field issues? AtlasIssuesKeymaps

---@alias AtlasKeymapActionId
---| "ui.help"
---| "ui.close"
---| "ui.toggle_panel"
---| "ui.toggle_fold"
---| "ui.toggle_all_folds"
---| "ui.previous_panel_tab"
---| "ui.next_panel_tab"
---| "ui.open_notifications"
---| "ui.notifications_mark_read"
---| "ui.notifications_mark_done"
---| "ui.notifications_refresh"
---| "ui.toggle_subscription"
---| "ui.refresh"
---| "ui.refresh_view"
---| "ui.open_actions"
---| "ui.open_in_browser"
---| "ui.copy_url"
---| "ui.show_details"
---| "ui.search"
---| "pulls.copy_id"
---| "pulls.open_diff"
---| "pulls.checkout"
---| "pulls.next_hunk"
---| "pulls.previous_hunk"
---| "pulls.filter_status_open"
---| "pulls.filter_status_merged"
---| "pulls.filter_status_declined"
---| "issues.copy_key"
---| "issues.transition_issue"
---| "issues.change_assignee"
---| "issues.change_reporter"
---| "issues.edit_issue"
---| "issues.create_issue"

---@param value AtlasKeymapValue
---@return string[]|nil
local function normalize(value)
	if value == false or value == nil then
		return nil
	end

	if type(value) == "string" then
		if value == "" then
			return nil
		end
		return { value }
	end

	if type(value) ~= "table" then
		return nil
	end

	local keys = {}
	for _, key in ipairs(value) do
		if type(key) == "string" and key ~= "" then
			table.insert(keys, key)
		end
	end

	if #keys == 0 then
		return nil
	end

	return keys
end

---@param action_id AtlasKeymapActionId|string
---@return AtlasKeymapValue
local function from_config(action_id)
	local group, key = tostring(action_id):match("^([^.]+)%.([^.]+)$")
	if group == nil or key == nil then
		return nil
	end

	local keymaps = require("atlas.config").options.keymaps
	if type(keymaps) ~= "table" then
		return nil
	end

	local section = keymaps[group]
	if type(section) ~= "table" then
		return nil
	end

	return section[key]
end

---@param action_id AtlasKeymapActionId|string
---@return string[]|nil
function M.resolve(action_id)
	return normalize(from_config(action_id))
end

---@param action_ids AtlasKeymapActionId[]
---@param builtins string[]
---@return table<string, string[]>
local function conflicts_for(action_ids, builtins)
	---@type table<string, table<string, true>>
	local seen_by_key = {}
	for _, action_id in ipairs(action_ids) do
		local keys = M.resolve(action_id) or {}
		for _, key in ipairs(keys) do
			seen_by_key[key] = seen_by_key[key] or {}
			seen_by_key[key][action_id] = true
		end
	end

	for _, key in ipairs(builtins) do
		seen_by_key[key] = seen_by_key[key] or {}
		seen_by_key[key]["builtin:" .. key] = true
	end

	---@type table<string, string[]>
	local conflicts = {}
	for key, seen in pairs(seen_by_key) do
		local actions = vim.tbl_keys(seen)
		table.sort(actions)
		if #actions > 1 then
			conflicts[key] = actions
		end
	end

	return conflicts
end

---@return table<string, table<string, string[]>>
function M.validate()
	return {
		ui = conflicts_for({
			"ui.help",
			"ui.close",
			"ui.toggle_panel",
			"ui.toggle_fold",
			"ui.toggle_all_folds",
			"ui.previous_panel_tab",
			"ui.next_panel_tab",
			"ui.open_notifications",
			"ui.toggle_subscription",
			"ui.refresh",
			"ui.refresh_view",
			"ui.open_actions",
			"ui.open_in_browser",
			"ui.copy_url",
			"ui.show_details",
			"ui.search",
		}, { "j", "k", "gg", "G" }),
		pulls = conflicts_for({
			"pulls.copy_id",
			"pulls.open_diff",
			"pulls.checkout",
			"pulls.next_hunk",
			"pulls.previous_hunk",
			"pulls.filter_status_open",
			"pulls.filter_status_merged",
			"pulls.filter_status_declined",
		}, { "j", "k", "gg", "G" }),
		issues = conflicts_for({
			"issues.copy_key",
			"issues.transition_issue",
			"issues.change_assignee",
			"issues.change_reporter",
			"issues.edit_issue",
			"issues.create_issue",
		}, { "j", "k", "gg", "G" }),
	}
end

return M
