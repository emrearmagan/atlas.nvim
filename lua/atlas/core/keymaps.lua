local M = {}

local config = require("atlas.config")

---@class AtlasUIKeymaps
---@field next_item? AtlasKeymapValue
---@field previous_item? AtlasKeymapValue
---@field previous_column? AtlasKeymapValue
---@field next_column? AtlasKeymapValue
---@field first_item? AtlasKeymapValue
---@field last_item? AtlasKeymapValue
---@field select? AtlasKeymapValue
---@field submit? AtlasKeymapValue
---@field help? AtlasKeymapValue
---@field close? AtlasKeymapValue
---@field delete? AtlasKeymapValue
---@field comments? AtlasUICommentKeymaps
---@field toggle_panel? AtlasKeymapValue
---@field cycle_layout? AtlasKeymapValue
---@field toggle_fold? AtlasKeymapValue
---@field toggle_all_folds? AtlasKeymapValue
---@field toggle_description_mode? AtlasKeymapValue
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
---@field open_references? AtlasKeymapValue
---@field copy_id? AtlasKeymapValue
---@field copy_url? AtlasKeymapValue
---@field show_details? AtlasKeymapValue
---@field search? AtlasKeymapValue
---@field edit_search? AtlasKeymapValue

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

---@class AtlasPullsReviewViewKeymaps
---@field external_help? AtlasKeymapValue
---@field toggle_review_panel? AtlasKeymapValue
---@field toggle_detail_panel? AtlasKeymapValue
---@field toggle_comments? AtlasKeymapValue

---@class AtlasPullsReviewExplorerKeymaps
---@field toggle_commits? AtlasKeymapValue
---@field next_unreviewed_file? AtlasKeymapValue
---@field prev_unreviewed_file? AtlasKeymapValue
---@field find_file? AtlasKeymapValue

---@class AtlasPullsReviewPanelKeymaps
---@field cycle_filter? AtlasKeymapValue

---@class AtlasPullsReviewAtlasKeymaps
---@field next_file? AtlasKeymapValue
---@field prev_file? AtlasKeymapValue
---@field toggle_explorer? AtlasKeymapValue
---@field focus_explorer? AtlasKeymapValue
---@field open_file? AtlasKeymapValue
---@field toggle_view_mode? AtlasKeymapValue
---@field next_hunk? AtlasKeymapValue
---@field prev_hunk? AtlasKeymapValue
---@field toggle_layout? AtlasKeymapValue
---@field toggle_compact? AtlasKeymapValue

---@class AtlasPullsReviewKeymaps
---@field show_details? AtlasKeymapValue
---@field toggle_file_reviewed? AtlasKeymapValue
---@field next_comment? AtlasKeymapValue
---@field prev_comment? AtlasKeymapValue
---@field next_unresolved? AtlasKeymapValue
---@field prev_unresolved? AtlasKeymapValue
---@field next_note? AtlasKeymapValue
---@field prev_note? AtlasKeymapValue
---@field next_commit? AtlasKeymapValue
---@field prev_commit? AtlasKeymapValue
---@field add_comment? AtlasKeymapValue
---@field submit_comment? AtlasKeymapValue
---@field add_suggestion? AtlasKeymapValue
---@field submit_suggestion? AtlasKeymapValue
---@field add_note? AtlasKeymapValue
---@field toggle_resolved? AtlasKeymapValue
---@field approve? AtlasKeymapValue
---@field request_changes? AtlasKeymapValue
---@field submit_review? AtlasKeymapValue
---@field add_task? AtlasKeymapValue
---@field comment_templates? AtlasKeymapValue
---@field view? AtlasPullsReviewViewKeymaps
---@field explorer? AtlasPullsReviewExplorerKeymaps
---@field panel? AtlasPullsReviewPanelKeymaps
---@field atlas? AtlasPullsReviewAtlasKeymaps

---@class AtlasPullsFilterKeymaps
---@field open? AtlasKeymapValue
---@field merged? AtlasKeymapValue
---@field declined? AtlasKeymapValue

---@class AtlasPullsPipelinesKeymaps
---@field next_job? AtlasKeymapValue
---@field previous_job? AtlasKeymapValue
---@field show_history? AtlasKeymapValue
---@field toggle_raw_logs? AtlasKeymapValue
---@field toggle_auto_refresh? AtlasKeymapValue
---@field toggle_config? AtlasKeymapValue

---@class AtlasPullsStackKeymaps
---@field next? AtlasKeymapValue
---@field prev? AtlasKeymapValue

---@class AtlasPullsCustomKeymap
---@field key string|string[]
---@field desc string
---@field callback fun(context: AtlasPullActionContext, done: fun(result: PullsActionResult|nil, err: string|nil)): any
---@field mode? string|string[]
---@field opts? table

---@class AtlasPullsKeymaps
---@field custom? AtlasPullsCustomKeymap[]
---@field open_diff? AtlasKeymapValue
---@field checkout? AtlasKeymapValue
---@field open_repository? AtlasKeymapValue
---@field edit_pr? AtlasKeymapValue
---@field stack? AtlasPullsStackKeymaps
---@field pipelines? AtlasPullsPipelinesKeymaps
---@field review? AtlasPullsReviewKeymaps
---@field filters? AtlasPullsFilterKeymaps

---@class AtlasIssuesCustomKeymap
---@field key string|string[]
---@field desc string
---@field callback fun(context: AtlasIssueActionContext, done: fun(result: IssuesActionResult|nil, err: string|nil)): any
---@field mode? string|string[]
---@field opts? table

---@class AtlasIssuesKeymaps
---@field custom? AtlasIssuesCustomKeymap[]
---@field transition_issue? AtlasKeymapValue
---@field change_assignee? AtlasKeymapValue
---@field change_reporter? AtlasKeymapValue
---@field edit_issue? AtlasKeymapValue
---@field create_issue? AtlasKeymapValue

---@class AtlasEditorKeymaps
---@field assignees? AtlasKeymapValue
---@field labels? AtlasKeymapValue
---@field milestone? AtlasKeymapValue
---@field reporter? AtlasKeymapValue
---@field reviewers? AtlasKeymapValue
---@field base? AtlasKeymapValue
---@field draft? AtlasKeymapValue
---@field issue_type? AtlasKeymapValue
---@field fields? AtlasKeymapValue
---@field templates? AtlasKeymapValue

---@class AtlasKeymapsConfig
---@field ui? AtlasUIKeymaps
---@field picker? AtlasPickerKeymaps
---@field pulls? AtlasPullsKeymaps
---@field issues? AtlasIssuesKeymaps
---@field editor? AtlasEditorKeymaps

---@alias AtlasKeymapActionId
---| "ui.next_item"
---| "ui.previous_item"
---| "ui.previous_column"
---| "ui.next_column"
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
---| "ui.cycle_layout"
---| "ui.toggle_fold"
---| "ui.toggle_all_folds"
---| "ui.toggle_description_mode"
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
---| "ui.open_references"
---| "ui.copy_id"
---| "ui.copy_url"
---| "ui.show_details"
---| "ui.search"
---| "ui.edit_search"
---| "picker.next_item"
---| "picker.previous_item"
---| "picker.select"
---| "picker.toggle"
---| "picker.close"
---| "pulls.open_diff"
---| "pulls.checkout"
---| "pulls.open_repository"
---| "pulls.edit_pr"
---| "pulls.stack.next"
---| "pulls.stack.prev"
---| "pulls.pipelines.next_job"
---| "pulls.pipelines.previous_job"
---| "pulls.pipelines.show_history"
---| "pulls.pipelines.toggle_raw_logs"
---| "pulls.pipelines.toggle_auto_refresh"
---| "pulls.pipelines.toggle_config"
---| "pulls.review.view.external_help"
---| "pulls.review.view.toggle_review_panel"
---| "pulls.review.view.toggle_detail_panel"
---| "pulls.review.view.toggle_comments"
---| "pulls.review.explorer.toggle_commits"
---| "pulls.review.explorer.next_unreviewed_file"
---| "pulls.review.explorer.prev_unreviewed_file"
---| "pulls.review.explorer.find_file"
---| "pulls.review.panel.cycle_filter"
---| "pulls.review.atlas.next_file"
---| "pulls.review.atlas.prev_file"
---| "pulls.review.atlas.toggle_explorer"
---| "pulls.review.atlas.focus_explorer"
---| "pulls.review.atlas.open_file"
---| "pulls.review.atlas.toggle_view_mode"
---| "pulls.review.atlas.next_hunk"
---| "pulls.review.atlas.prev_hunk"
---| "pulls.review.atlas.toggle_layout"
---| "pulls.review.atlas.toggle_compact"
---| "pulls.review.show_details"
---| "pulls.review.toggle_file_reviewed"
---| "pulls.review.next_comment"
---| "pulls.review.prev_comment"
---| "pulls.review.next_unresolved"
---| "pulls.review.prev_unresolved"
---| "pulls.review.next_note"
---| "pulls.review.prev_note"
---| "pulls.review.next_commit"
---| "pulls.review.prev_commit"
---| "pulls.review.add_comment"
---| "pulls.review.submit_comment"
---| "pulls.review.add_suggestion"
---| "pulls.review.submit_suggestion"
---| "pulls.review.add_note"
---| "pulls.review.toggle_resolved"
---| "pulls.review.approve"
---| "pulls.review.request_changes"
---| "pulls.review.submit_review"
---| "pulls.review.add_task"
---| "pulls.review.comment_templates"
---| "pulls.filters.open"
---| "pulls.filters.merged"
---| "pulls.filters.declined"
---| "issues.transition_issue"
---| "issues.change_assignee"
---| "issues.change_reporter"
---| "issues.edit_issue"
---| "issues.create_issue"
---| "editor.assignees"
---| "editor.labels"
---| "editor.milestone"
---| "editor.reporter"
---| "editor.reviewers"
---| "editor.base"
---| "editor.draft"
---| "editor.issue_type"
---| "editor.fields"
---| "editor.templates"

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
	local value = config.options.keymaps
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

---@param domain "pulls"|"issues"
---@param run fun(callback: function): any
---@return AtlasHelpKeyItem[]
function M.custom_items(domain, run)
	local items = {}
	for _, mapping in ipairs((config.options.keymaps[domain] or {}).custom or {}) do
		local item = vim.deepcopy(mapping)
		item.callback = function()
			return run(mapping.callback)
		end
		items[#items + 1] = item
	end
	return items
end

---@return table<string, table<string, string[]>>
function M.validate()
	-- TODO: Give these actions unique default mappings.
	---@type AtlasKeymapActionId[][]
	local ALLOWED_CONFLICTS = {
		{ "ui.comments.add", "ui.edit_search" },
		{ "ui.next_panel_tab", "pulls.pipelines.next_job" },
		{ "ui.previous_panel_tab", "pulls.pipelines.previous_job" },
		{ "ui.comments.reply", "issues.create_issue" },
		{ "ui.comments.react", "issues.change_reporter" },
		{ "editor.reporter", "editor.reviewers" },
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

	local custom_keys = {}
	local function collect_actions(node, path, action_ids)
		for name, value in pairs(node) do
			local action_id = path .. "." .. name
			local notification_action = action_id == "ui.notifications.mark_read"
				or action_id == "ui.notifications.mark_done"
			if name == "custom" then
				for index, mapping in ipairs(value) do
					local id = action_id .. "." .. index
					custom_keys[id] = normalize(mapping.key)
					table.insert(action_ids, id)
				end
			elseif not notification_action and action_id ~= "pulls.review" then
				if normalize(value) then
					table.insert(action_ids, action_id)
				elseif type(value) == "table" then
					collect_actions(value, action_id, action_ids)
				end
			end
		end
	end

	local keymaps = config.options.keymaps
	---@cast keymaps -nil
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
			for _, key in ipairs(custom_keys[action_id] or M.resolve(action_id) or {}) do
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

	-- Column navigation is registered only by issue dashboards.
	local pulls_actions = actions_for({ "ui", "pulls" })
	for index = #pulls_actions, 1, -1 do
		local action_id = pulls_actions[index]
		if action_id == "ui.previous_column" or action_id == "ui.next_column" then
			table.remove(pulls_actions, index)
		end
	end

	local result = {
		picker = conflicts_for(actions_for({ "picker" })),
		ui = conflicts_for(actions_for({ "ui" })),
		pulls = conflicts_for(vim.list_extend(pulls_actions, {
			"pulls.review.approve",
			"pulls.review.request_changes",
			"pulls.review.submit_review",
			"pulls.review.add_task",
			"pulls.review.comment_templates",
		})),
		issues = conflicts_for(actions_for({ "ui", "issues" })),
		editor = conflicts_for(vim.list_extend(actions_for({ "editor" }), {
			"ui.submit",
			"ui.close",
			"ui.help",
			"ui.toggle_description_mode",
			"pulls.open_diff",
		})),
		notifications = conflicts_for({
			"ui.notifications.mark_read",
			"ui.notifications.mark_done",
			"ui.refresh_view",
			"ui.select",
			"ui.open_in_browser",
			"ui.close",
		}),
	}

	return result
end

return M
