local M = {}

---@class AtlasUIKeymaps
---@field next_item? AtlasKeymapValue
---@field previous_item? AtlasKeymapValue
---@field first_item? AtlasKeymapValue
---@field last_item? AtlasKeymapValue
---@field submit? AtlasKeymapValue
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
---@field copy_id? AtlasKeymapValue
---@field copy_url? AtlasKeymapValue
---@field show_details? AtlasKeymapValue
---@field search? AtlasKeymapValue

---@class AtlasPullsReviewExplorerKeymaps
---@field next_file? AtlasKeymapValue
---@field previous_file? AtlasKeymapValue
---@field next_unreviewed_file? AtlasKeymapValue
---@field previous_unreviewed_file? AtlasKeymapValue
---@field toggle_grouping? AtlasKeymapValue
---@field toggle_file_reviewed? AtlasKeymapValue
---@field toggle_commits? AtlasKeymapValue

---@class AtlasPullsReviewDiffKeymaps
---@field toggle_layout? AtlasKeymapValue
---@field toggle_compact? AtlasKeymapValue
---@field next_hunk? AtlasKeymapValue
---@field previous_hunk? AtlasKeymapValue
---@field toggle_review_panel? AtlasKeymapValue
---@field toggle_comments? AtlasKeymapValue
---@field next_comment? AtlasKeymapValue
---@field previous_comment? AtlasKeymapValue
---@field next_note? AtlasKeymapValue
---@field previous_note? AtlasKeymapValue
---@field add_comment? AtlasKeymapValue
---@field submit_comment? AtlasKeymapValue
---@field add_suggestion? AtlasKeymapValue
---@field submit_suggestion? AtlasKeymapValue
---@field edit_comment? AtlasKeymapValue
---@field delete? AtlasKeymapValue
---@field add_note? AtlasKeymapValue
---@field add_task? AtlasKeymapValue
---@field toggle_resolved? AtlasKeymapValue

---@class AtlasPullsReviewKeymaps
---@field show_item? AtlasKeymapValue
---@field focus_item? AtlasKeymapValue
---@field toggle_approval? AtlasKeymapValue
---@field request_changes? AtlasKeymapValue
---@field submit_review? AtlasKeymapValue
---@field explorer? AtlasPullsReviewExplorerKeymaps
---@field diff? AtlasPullsReviewDiffKeymaps

---@class AtlasPullsPipelinesKeymaps
---@field open? AtlasKeymapValue

---@class AtlasPullsFilterKeymaps
---@field open? AtlasKeymapValue
---@field merged? AtlasKeymapValue
---@field declined? AtlasKeymapValue

---@class AtlasPullsKeymaps
---@field open_diff? AtlasKeymapValue
---@field checkout? AtlasKeymapValue
---@field edit_title? AtlasKeymapValue
---@field edit_description? AtlasKeymapValue
---@field review? AtlasPullsReviewKeymaps
---@field pipelines? AtlasPullsPipelinesKeymaps
---@field filters? AtlasPullsFilterKeymaps

---@class AtlasIssuesKeymaps
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
---| "ui.next_item"
---| "ui.previous_item"
---| "ui.first_item"
---| "ui.last_item"
---| "ui.submit"
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
---| "ui.copy_id"
---| "ui.copy_url"
---| "ui.show_details"
---| "ui.search"
---| "pulls.open_diff"
---| "pulls.checkout"
---| "pulls.edit_title"
---| "pulls.edit_description"
---| "pulls.review.toggle_approval"
---| "pulls.review.request_changes"
---| "pulls.review.submit_review"
---| "pulls.review.show_item"
---| "pulls.review.focus_item"
---| "pulls.review.explorer.next_file"
---| "pulls.review.explorer.previous_file"
---| "pulls.review.explorer.next_unreviewed_file"
---| "pulls.review.explorer.previous_unreviewed_file"
---| "pulls.review.explorer.toggle_grouping"
---| "pulls.review.explorer.toggle_file_reviewed"
---| "pulls.review.explorer.toggle_commits"
---| "pulls.review.diff.toggle_layout"
---| "pulls.review.diff.toggle_compact"
---| "pulls.review.diff.next_hunk"
---| "pulls.review.diff.previous_hunk"
---| "pulls.review.diff.toggle_review_panel"
---| "pulls.review.diff.toggle_comments"
---| "pulls.review.diff.next_comment"
---| "pulls.review.diff.previous_comment"
---| "pulls.review.diff.next_note"
---| "pulls.review.diff.previous_note"
---| "pulls.review.diff.add_comment"
---| "pulls.review.diff.submit_comment"
---| "pulls.review.diff.add_suggestion"
---| "pulls.review.diff.submit_suggestion"
---| "pulls.review.diff.edit_comment"
---| "pulls.review.diff.delete"
---| "pulls.review.diff.add_note"
---| "pulls.review.diff.add_task"
---| "pulls.review.diff.toggle_resolved"
---| "pulls.pipelines.open"
---| "pulls.filters.open"
---| "pulls.filters.merged"
---| "pulls.filters.declined"
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
	local value = require("atlas.config").options.keymaps
	for key in tostring(action_id):gmatch("[^.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

---@param action_id AtlasKeymapActionId|string
---@return string[]|nil
function M.resolve(action_id)
	return normalize(from_config(action_id))
end

-- Navigation is bound in every Atlas buffer, so these participate in the
-- conflict check for every section.
---@type AtlasKeymapActionId[]
local NAV_ACTIONS = {
	"ui.next_item",
	"ui.previous_item",
	"ui.first_item",
	"ui.last_item",
}

---@param action_ids AtlasKeymapActionId[]
---@return table<string, string[]>
local function conflicts_for(action_ids)
	---@type table<string, table<string, true>>
	local seen_by_key = {}

	---@param ids AtlasKeymapActionId[]
	local function collect(ids)
		for _, action_id in ipairs(ids) do
			local keys = M.resolve(action_id) or {}
			for _, key in ipairs(keys) do
				seen_by_key[key] = seen_by_key[key] or {}
				seen_by_key[key][action_id] = true
			end
		end
	end

	collect(NAV_ACTIONS)
	collect(action_ids)

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

---@param section_path string[]
---@return { key?: string, label?: string, items?: table }|nil
local function get_bookmarks(section_path)
	local node = require("atlas.config").options ---@type any
	for _, key in ipairs(section_path) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	if type(node) ~= "table" then
		return nil
	end
	return node.bookmarks
end

---@param section_path string[]
---@param default_bookmarks_key string
---@return table<string, string[]>
local function view_key_conflicts(section_path, default_bookmarks_key)
	local node = require("atlas.config").options ---@type any
	for _, key in ipairs(section_path) do
		if type(node) ~= "table" then
			return {}
		end
		node = node[key]
	end
	if type(node) ~= "table" then
		return {}
	end

	---@type table<string, table<string, true>>
	local seen = {}
	for _, view in ipairs(node.views or {}) do
		local key = type(view) == "table" and view.key or nil
		if type(key) == "string" and key ~= "" then
			seen[key] = seen[key] or {}
			seen[key][tostring(view.name or "<view>")] = true
		end
	end

	local bookmarks = get_bookmarks(section_path)
	if type(bookmarks) == "table" and type(bookmarks.items) == "table" and next(bookmarks.items) ~= nil then
		local bk = tostring(bookmarks.key or default_bookmarks_key)
		if bk ~= "" then
			seen[bk] = seen[bk] or {}
			seen[bk][tostring(bookmarks.label or default_bookmarks_key) .. " (bookmarks)"] = true
		end
	end

	---@type table<string, string[]>
	local conflicts = {}
	for key, names in pairs(seen) do
		local list = vim.tbl_keys(names)
		table.sort(list)
		if #list > 1 then
			conflicts[key] = list
		end
	end
	return conflicts
end

---@return table<string, table<string, string[]>>
function M.validate()
	local result = {
		ui = conflicts_for({
			"ui.submit",
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
			"ui.copy_id",
			"ui.copy_url",
			"ui.show_details",
			"ui.search",
		}),
		pulls = conflicts_for({
			"pulls.open_diff",
			"pulls.checkout",
			"pulls.edit_title",
			"pulls.edit_description",
			"pulls.filters.open",
			"pulls.filters.merged",
			"pulls.filters.declined",
		}),
		["pull review"] = conflicts_for({
			"pulls.review.toggle_approval",
			"pulls.review.request_changes",
			"pulls.review.submit_review",
			"pulls.review.show_item",
			"pulls.review.focus_item",
			"pulls.review.explorer.next_file",
			"pulls.review.explorer.previous_file",
			"pulls.review.explorer.next_unreviewed_file",
			"pulls.review.explorer.previous_unreviewed_file",
			"pulls.review.explorer.toggle_grouping",
			"pulls.review.explorer.toggle_file_reviewed",
			"pulls.review.explorer.toggle_commits",
			"pulls.review.diff.toggle_layout",
			"pulls.review.diff.toggle_compact",
			"pulls.review.diff.next_hunk",
			"pulls.review.diff.previous_hunk",
			"pulls.review.diff.toggle_review_panel",
			"pulls.review.diff.toggle_comments",
			"pulls.review.diff.next_comment",
			"pulls.review.diff.previous_comment",
			"pulls.review.diff.next_note",
			"pulls.review.diff.previous_note",
			"pulls.review.diff.add_comment",
			"pulls.review.diff.submit_comment",
			"pulls.review.diff.add_suggestion",
			"pulls.review.diff.submit_suggestion",
			"pulls.review.diff.delete",
			"pulls.review.diff.add_note",
			"pulls.review.diff.toggle_resolved",
		}),
		pipelines = conflicts_for({ "pulls.pipelines.open" }),
		issues = conflicts_for({
			"issues.transition_issue",
			"issues.change_assignee",
			"issues.change_reporter",
			"issues.edit_issue",
			"issues.create_issue",
		}),
	}

	for _, domain in ipairs({ "issues", "pulls" }) do
		for _, provider in ipairs(require("atlas.providers").list(domain)) do
			local provider_domain = provider.domains[domain]
			local conflicts =
				view_key_conflicts({ domain, "providers", provider.id }, provider_domain.bookmark_key or "")
			if next(conflicts) ~= nil then
				result[string.format("%s %s views", provider.name:lower(), domain)] = conflicts
			end
		end
	end

	return result
end

return M
