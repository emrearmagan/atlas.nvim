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
---@field upvote? AtlasKeymapValue

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
---@field note_type? AtlasKeymapValue
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

---@class AtlasPullsMergeKeymaps
---@field method? AtlasKeymapValue
---@field delete_branch? AtlasKeymapValue

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
---@field merge? AtlasPullsMergeKeymaps

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
---@field delete_template? AtlasKeymapValue
---@field complete? AtlasKeymapValue

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
---| "ui.comments.upvote"
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
---| "pulls.review.note_type"
---| "pulls.review.toggle_resolved"
---| "pulls.review.approve"
---| "pulls.review.request_changes"
---| "pulls.review.submit_review"
---| "pulls.review.add_task"
---| "pulls.review.comment_templates"
---| "pulls.filters.open"
---| "pulls.filters.merged"
---| "pulls.filters.declined"
---| "pulls.merge.method"
---| "pulls.merge.delete_branch"
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
---| "editor.delete_template"
---| "editor.complete"

---@class AtlasKeymap
---@field key? string[]
---@field desc string
---@field label string

local descriptions = {
	ui = {
		next_item = { desc = "Next item", label = "next" },
		previous_item = { desc = "Previous item", label = "previous" },
		previous_column = { desc = "Previous status column", label = "previous column" },
		next_column = { desc = "Next status column", label = "next column" },
		first_item = { desc = "Go to first item", label = "first" },
		last_item = { desc = "Go to last item", label = "last" },
		select = { desc = "Open", label = "open" },
		submit = { desc = "Submit", label = "submit" },
		help = { desc = "Toggle help", label = "help" },
		close = { desc = "Close", label = "close" },
		delete = { desc = "Delete", label = "delete" },
		comments = {
			add = { desc = "Add comment", label = "comment" },
			reply = { desc = "Reply to comment", label = "reply" },
			edit = { desc = "Edit comment", label = "edit" },
			react = { desc = "Add reaction", label = "react" },
			upvote = { desc = "Toggle upvote", label = "upvote" },
		},
		toggle_panel = { desc = "Toggle detail panel", label = "panel" },
		cycle_layout = { desc = "Cycle layout", label = "layout" },
		toggle_fold = { desc = "Expand / collapse", label = "fold" },
		toggle_all_folds = { desc = "Expand / collapse all", label = "fold all" },
		toggle_description_mode = { desc = "Toggle description mode", label = "raw" },
		previous_panel_tab = { desc = "Previous tab", label = "previous tab" },
		next_panel_tab = { desc = "Next tab", label = "next tab" },
		notifications = {
			open = { desc = "Open notifications", label = "notifications" },
			mark_read = { desc = "Mark as read", label = "mark read" },
			mark_done = { desc = "Mark as done", label = "mark done" },
		},
		toggle_subscription = { desc = "Toggle subscription", label = "subscribe" },
		toggle_star = { desc = "Star / unstar", label = "star" },
		refresh = { desc = "Refresh", label = "refresh" },
		refresh_view = { desc = "Refresh view", label = "refresh" },
		next_page = { desc = "Next page", label = "next page" },
		previous_page = { desc = "Previous page", label = "previous page" },
		open_actions = { desc = "Open actions", label = "actions" },
		open_in_browser = { desc = "Open in browser", label = "browser" },
		open_references = { desc = "Open references", label = "references" },
		copy_id = { desc = "Copy ID", label = "copy id" },
		copy_url = { desc = "Copy URL", label = "copy url" },
		show_details = { desc = "Show details", label = "details" },
		search = { desc = "Search", label = "search" },
		edit_search = { desc = "Edit search", label = "edit search" },
	},
	picker = {
		next_item = { desc = "Next item", label = "next" },
		previous_item = { desc = "Previous item", label = "previous" },
		select = { desc = "Select", label = "select" },
		toggle = { desc = "Toggle selection", label = "toggle" },
		close = { desc = "Close", label = "close" },
	},
	pulls = {
		open_diff = { desc = "Open diff", label = "diff" },
		checkout = { desc = "Checkout branch", label = "checkout" },
		open_repository = { desc = "Open repository browser", label = "repository" },
		edit_pr = { desc = "Edit PR", label = "edit" },
		stack = {
			next = { desc = "Next PR in stack", label = "next PR" },
			prev = { desc = "Previous PR in stack", label = "previous PR" },
		},
		pipelines = {
			next_job = { desc = "Next job", label = "next job" },
			previous_job = { desc = "Previous job", label = "previous job" },
			show_history = { desc = "Show build history", label = "history" },
			toggle_raw_logs = { desc = "Toggle raw logs", label = "raw" },
			toggle_auto_refresh = { desc = "Toggle auto refresh", label = "auto refresh" },
			toggle_config = { desc = "Toggle configuration", label = "config" },
		},
		review = {
			show_details = { desc = "Show details", label = "details" },
			toggle_file_reviewed = { desc = "Toggle reviewed", label = "reviewed" },
			next_comment = { desc = "Next comment", label = "next comment" },
			prev_comment = { desc = "Previous comment", label = "previous comment" },
			next_unresolved = { desc = "Next unresolved thread", label = "next unresolved" },
			prev_unresolved = { desc = "Previous unresolved thread", label = "previous unresolved" },
			next_note = { desc = "Next note", label = "next note" },
			prev_note = { desc = "Previous note", label = "previous note" },
			next_commit = { desc = "Next commit", label = "next commit" },
			prev_commit = { desc = "Previous commit", label = "previous commit" },
			add_comment = { desc = "Add pending comment", label = "pending comment" },
			submit_comment = { desc = "Post comment", label = "comment" },
			add_suggestion = { desc = "Add pending suggestion", label = "pending suggestion" },
			submit_suggestion = { desc = "Post suggestion", label = "suggestion" },
			add_note = { desc = "Add note", label = "note" },
			note_type = { desc = "Cycle note type", label = "type" },
			toggle_resolved = { desc = "Toggle resolved", label = "resolve" },
			approve = { desc = "Approve", label = "approve" },
			request_changes = { desc = "Request changes", label = "request changes" },
			submit_review = { desc = "Submit review", label = "submit review" },
			add_task = { desc = "Add task", label = "task" },
			comment_templates = { desc = "Insert template", label = "templates" },
			view = {
				external_help = { desc = "Show diff viewer help", label = "viewer help" },
				toggle_review_panel = { desc = "Toggle review panel", label = "review panel" },
				toggle_detail_panel = { desc = "Toggle PR details", label = "details" },
				toggle_comments = { desc = "Toggle comment display", label = "comments" },
			},
			explorer = {
				toggle_commits = { desc = "Toggle commits", label = "commits" },
				next_unreviewed_file = { desc = "Next unreviewed file", label = "next unreviewed" },
				prev_unreviewed_file = { desc = "Previous unreviewed file", label = "previous unreviewed" },
				find_file = { desc = "Find changed file", label = "find file" },
			},
			panel = {
				cycle_filter = { desc = "Cycle filter", label = "filter" },
			},
			atlas = {
				next_file = { desc = "Next file", label = "next file" },
				prev_file = { desc = "Previous file", label = "previous file" },
				toggle_explorer = { desc = "Toggle explorer", label = "explorer" },
				focus_explorer = { desc = "Focus explorer", label = "focus explorer" },
				open_file = { desc = "Open local file", label = "open file" },
				toggle_view_mode = { desc = "Toggle explorer mode", label = "tree" },
				next_hunk = { desc = "Next hunk", label = "next hunk" },
				prev_hunk = { desc = "Previous hunk", label = "previous hunk" },
				toggle_layout = { desc = "Toggle diff layout", label = "layout" },
				toggle_compact = { desc = "Toggle compact mode", label = "compact" },
			},
		},
		filters = {
			open = { desc = "Toggle open filter", label = "open" },
			merged = { desc = "Toggle merged filter", label = "merged" },
			declined = { desc = "Toggle declined filter", label = "declined" },
		},
		merge = {
			method = { desc = "Change merge method", label = "method" },
			delete_branch = { desc = "Toggle source branch deletion", label = "delete branch" },
		},
	},
	issues = {
		transition_issue = { desc = "Transition issue", label = "transition" },
		change_assignee = { desc = "Change assignee", label = "assignee" },
		change_reporter = { desc = "Change reporter", label = "reporter" },
		edit_issue = { desc = "Edit issue", label = "edit" },
		create_issue = { desc = "Create issue", label = "create" },
	},
	editor = {
		assignees = { desc = "Change assignees", label = "assignees" },
		labels = { desc = "Change labels", label = "labels" },
		milestone = { desc = "Change milestone", label = "milestone" },
		reporter = { desc = "Change reporter", label = "reporter" },
		reviewers = { desc = "Change reviewers", label = "reviewers" },
		base = { desc = "Change base branch", label = "base" },
		draft = { desc = "Toggle draft", label = "draft" },
		issue_type = { desc = "Change issue type", label = "issue type" },
		fields = { desc = "Edit fields", label = "fields" },
		templates = { desc = "Insert template", label = "templates" },
		delete_template = { desc = "Delete template", label = "delete" },
		complete = { desc = "Complete Atlas references", label = "complete" },
	},
}

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

---@param value table|nil
---@param action_id string
---@return any
local function lookup(value, action_id)
	for key in action_id:gmatch("[^.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

---@param action_id AtlasKeymapActionId|AtlasKeymapActionId[]
---@return AtlasKeymap|nil
function M.resolve(action_id)
	---@type AtlasKeymapActionId[]
	local action_ids = type(action_id) == "table" and action_id or { action_id }
	local keymap = assert(lookup(descriptions, action_ids[1]), "Unknown keymap: " .. tostring(action_ids[1]))

	local keys = {}
	for _, id in ipairs(action_ids) do
		vim.list_extend(keys, normalize(lookup(config.options.keymaps, id)) or {})
	end

	if #keys == 0 then
		return nil
	end
	return { key = keys, desc = keymap.desc, label = keymap.label }
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
	local result = {}

	---@param node table
	---@param path string
	local function check(node, path)
		local seen = {}
		local function add(keys, action_id)
			for _, key in ipairs(keys or {}) do
				seen[key] = seen[key] or {}
				table.insert(seen[key], action_id)
			end
		end

		for name, value in pairs(node) do
			local action_id = path .. "." .. name
			local keys = normalize(value)
			if name == "custom" then
				for index, mapping in ipairs(value) do
					add(normalize(mapping.key), action_id .. "." .. index)
				end
			elseif keys then
				add(keys, action_id)
			elseif type(value) == "table" then
				check(value, action_id)
			end
		end

		local conflicts = {}
		for key, action_ids in pairs(seen) do
			if #action_ids > 1 then
				table.sort(action_ids)
				conflicts[key] = action_ids
			end
		end
		if next(conflicts) then
			result[path] = conflicts
		end
	end

	for namespace, node in pairs(config.options.keymaps) do
		check(node, namespace)
	end
	return result
end

return M
