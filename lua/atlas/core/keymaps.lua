local M = {}

---@class AtlasUIKeymaps
---@field next_item? AtlasKeymapValue
---@field previous_item? AtlasKeymapValue
---@field first_item? AtlasKeymapValue
---@field last_item? AtlasKeymapValue
---@field select? AtlasKeymapValue
---@field submit? AtlasKeymapValue
---@field help? AtlasKeymapValue
---@field close? AtlasKeymapValue
---@field delete? AtlasKeymapValue
---@field comments? AtlasUICommentKeymaps
---@field toggle_panel? AtlasKeymapValue
---@field toggle_fold? AtlasKeymapValue
---@field toggle_all_folds? AtlasKeymapValue
---@field previous_panel_tab? AtlasKeymapValue
---@field next_panel_tab? AtlasKeymapValue
---@field notifications? AtlasUINotificationKeymaps
---@field toggle_subscription? AtlasKeymapValue
---@field toggle_star? AtlasKeymapValue
---@field refresh? AtlasKeymapValue
---@field refresh_view? AtlasKeymapValue
---@field next_page? AtlasKeymapValue
---@field previous_page? AtlasKeymapValue
---@field open_actions? AtlasKeymapValue
---@field open_in_browser? AtlasKeymapValue
---@field copy_id? AtlasKeymapValue
---@field copy_url? AtlasKeymapValue
---@field show_details? AtlasKeymapValue
---@field search? AtlasKeymapValue

---@class AtlasUICommentKeymaps
---@field add? AtlasKeymapValue
---@field reply? AtlasKeymapValue
---@field edit? AtlasKeymapValue
---@field react? AtlasKeymapValue

---@class AtlasUINotificationKeymaps
---@field open? AtlasKeymapValue
---@field mark_read? AtlasKeymapValue
---@field mark_done? AtlasKeymapValue

---@class AtlasPickerKeymaps
---@field next_item? AtlasKeymapValue
---@field previous_item? AtlasKeymapValue
---@field select? AtlasKeymapValue
---@field toggle? AtlasKeymapValue
---@field close? AtlasKeymapValue

---@class AtlasPullsReviewExplorerKeymaps
---@field find_file? AtlasKeymapValue
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
---@field toggle_detail_panel? AtlasKeymapValue
---@field toggle_comments? AtlasKeymapValue
---@field next_comment? AtlasKeymapValue
---@field previous_comment? AtlasKeymapValue
---@field next_note? AtlasKeymapValue
---@field previous_note? AtlasKeymapValue
---@field add_comment? AtlasKeymapValue
---@field submit_comment? AtlasKeymapValue
---@field add_suggestion? AtlasKeymapValue
---@field submit_suggestion? AtlasKeymapValue
---@field add_note? AtlasKeymapValue
---@field toggle_resolved? AtlasKeymapValue

---@class AtlasPullsReviewKeymaps
---@field focus_item? AtlasKeymapValue
---@field approve? AtlasKeymapValue
---@field request_changes? AtlasKeymapValue
---@field submit_review? AtlasKeymapValue
---@field add_task? AtlasKeymapValue
---@field comment_templates? AtlasKeymapValue
---@field find_file? AtlasKeymapValue
---@field explorer? AtlasPullsReviewExplorerKeymaps
---@field diff? AtlasPullsReviewDiffKeymaps

---@class AtlasPullsFilterKeymaps
---@field open? AtlasKeymapValue
---@field merged? AtlasKeymapValue
---@field declined? AtlasKeymapValue

---@class AtlasPullsKeymaps
---@field open_diff? AtlasKeymapValue
---@field checkout? AtlasKeymapValue
---@field external_help? AtlasKeymapValue
---@field toggle_repo_panel? AtlasKeymapValue
---@field toggle_repo_issue_state? AtlasKeymapValue
---@field edit_title? AtlasKeymapValue
---@field edit_description? AtlasKeymapValue
---@field review? AtlasPullsReviewKeymaps
---@field filters? AtlasPullsFilterKeymaps

---@class AtlasIssuesKeymaps
---@field transition_issue? AtlasKeymapValue
---@field change_assignee? AtlasKeymapValue
---@field change_reporter? AtlasKeymapValue
---@field edit_issue? AtlasKeymapValue
---@field create_issue? AtlasKeymapValue
---@field toggle_description_mode? AtlasKeymapValue

---@class AtlasKeymapsConfig
---@field ui? AtlasUIKeymaps
---@field picker? AtlasPickerKeymaps
---@field pulls? AtlasPullsKeymaps
---@field issues? AtlasIssuesKeymaps

---@alias AtlasKeymapActionId
---| "ui.next_item"
---| "ui.previous_item"
---| "ui.first_item"
---| "ui.last_item"
---| "ui.select"
---| "ui.submit"
---| "ui.help"
---| "ui.close"
---| "ui.delete"
---| "ui.comments.add"
---| "ui.comments.reply"
---| "ui.comments.edit"
---| "ui.comments.react"
---| "ui.toggle_panel"
---| "ui.toggle_fold"
---| "ui.toggle_all_folds"
---| "ui.previous_panel_tab"
---| "ui.next_panel_tab"
---| "ui.notifications.open"
---| "ui.notifications.mark_read"
---| "ui.notifications.mark_done"
---| "ui.toggle_subscription"
---| "ui.toggle_star"
---| "ui.refresh"
---| "ui.refresh_view"
---| "ui.next_page"
---| "ui.previous_page"
---| "ui.open_actions"
---| "ui.open_in_browser"
---| "ui.copy_id"
---| "ui.copy_url"
---| "ui.show_details"
---| "ui.search"
---| "picker.next_item"
---| "picker.previous_item"
---| "picker.select"
---| "picker.toggle"
---| "picker.close"
---| "pulls.open_diff"
---| "pulls.checkout"
---| "pulls.external_help"
---| "pulls.toggle_repo_panel"
---| "pulls.toggle_repo_issue_state"
---| "pulls.edit_title"
---| "pulls.edit_description"
---| "pulls.review.approve"
---| "pulls.review.request_changes"
---| "pulls.review.submit_review"
---| "pulls.review.add_task"
---| "pulls.review.comment_templates"
---| "pulls.review.focus_item"
---| "pulls.review.find_file"
---| "pulls.review.explorer.find_file"
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
---| "pulls.review.diff.toggle_detail_panel"
---| "pulls.review.diff.toggle_comments"
---| "pulls.review.diff.next_comment"
---| "pulls.review.diff.previous_comment"
---| "pulls.review.diff.next_note"
---| "pulls.review.diff.previous_note"
---| "pulls.review.diff.add_comment"
---| "pulls.review.diff.submit_comment"
---| "pulls.review.diff.add_suggestion"
---| "pulls.review.diff.submit_suggestion"
---| "pulls.review.diff.add_note"
---| "pulls.review.diff.toggle_resolved"
---| "pulls.filters.open"
---| "pulls.filters.merged"
---| "pulls.filters.declined"
---| "issues.transition_issue"
---| "issues.change_assignee"
---| "issues.change_reporter"
---| "issues.edit_issue"
---| "issues.create_issue"
---| "issues.toggle_description_mode"

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
	if default_bookmarks_key ~= "" then
		local bk = tostring((type(bookmarks) == "table" and bookmarks.key) or default_bookmarks_key)
		if bk ~= "" then
			seen[bk] = seen[bk] or {}
			seen[bk][tostring((type(bookmarks) == "table" and bookmarks.label) or default_bookmarks_key) .. " (bookmarks)"] =
				true
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
	-- TODO: Give these actions unique default mappings.
	---@type AtlasKeymapActionId[][]
	local ALLOWED_CONFLICTS = {
		{ "pulls.review.find_file", "pulls.review.explorer.find_file" },
		{ "ui.next_panel_tab", "pulls.review.explorer.next_file" },
		{ "ui.previous_panel_tab", "pulls.review.explorer.previous_file" },
		{ "ui.comments.reply", "pulls.review.diff.add_comment", "issues.create_issue" },
		{ "pulls.edit_title", "pulls.review.explorer.toggle_grouping" },
		{ "pulls.toggle_repo_issue_state", "pulls.review.diff.toggle_layout" },
		{ "pulls.checkout", "pulls.review.diff.toggle_compact" },
		{ "pulls.open_diff", "pulls.review.focus_item" },
		{
			"ui.comments.react",
			"pulls.review.request_changes",
			"issues.change_reporter",
		},
	}

	local function conflict_allowed(actions)
		for _, group in ipairs(ALLOWED_CONFLICTS) do
			local allowed = {}
			for _, action_id in ipairs(group) do
				allowed[action_id] = true
			end

			local matches = true
			for _, action_id in ipairs(actions) do
				if not allowed[action_id] then
					matches = false
					break
				end
			end
			if matches then
				return true
			end
		end
		return false
	end

	local function collect_actions(node, path, action_ids)
		for name, value in pairs(node) do
			local action_id = path .. "." .. name
			local notification_action = action_id == "ui.notifications.mark_read"
				or action_id == "ui.notifications.mark_done"
			if not notification_action then
				if normalize(value) then
					table.insert(action_ids, action_id)
				elseif type(value) == "table" then
					collect_actions(value, action_id, action_ids)
				end
			end
		end
	end

	local keymaps = require("atlas.config").options.keymaps
	local function actions_for(namespaces)
		local action_ids = {}
		for _, namespace in ipairs(namespaces) do
			collect_actions(keymaps[namespace] or {}, namespace, action_ids)
		end
		return action_ids
	end

	local function conflicts_for(action_ids)
		local seen_by_key = {}
		for _, action_id in ipairs(action_ids) do
			for _, key in ipairs(M.resolve(action_id) or {}) do
				seen_by_key[key] = seen_by_key[key] or {}
				seen_by_key[key][action_id] = true
			end
		end

		local conflicts = {}
		for key, seen in pairs(seen_by_key) do
			local actions = vim.tbl_keys(seen)
			table.sort(actions)
			if #actions > 1 and not conflict_allowed(actions) then
				conflicts[key] = actions
			end
		end
		return conflicts
	end

	local result = {
		picker = conflicts_for(actions_for({ "picker" })),
		ui = conflicts_for(actions_for({ "ui" })),
		pulls = conflicts_for(actions_for({ "ui", "pulls" })),
		issues = conflicts_for(actions_for({ "ui", "issues" })),
		notifications = conflicts_for({
			"ui.notifications.mark_read",
			"ui.notifications.mark_done",
			"ui.refresh_view",
			"ui.open_in_browser",
			"ui.close",
		}),
	}

	for _, domain in ipairs({ "issues", "pulls" }) do
		for _, provider in ipairs(require("atlas.providers").list(domain)) do
			local provider_domain = provider.domains[domain]
			local conflicts = view_key_conflicts({ domain, provider.id }, provider_domain.bookmark_key or "S")
			if next(conflicts) ~= nil then
				result[string.format("%s %s views", provider.name:lower(), domain)] = conflicts
			end
		end
	end

	return result
end

return M
