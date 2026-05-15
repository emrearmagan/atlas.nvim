local icons = require("atlas.ui.shared.icons")
local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()

---@class GitLabIssuesProvider : IssuesProvider
local M = {
	id = "gitlab",
	name = "GitLab",
	icon = icons.issues_provider("gitlab", "provider"),
	hl_group = "AtlasGLIssuesTheme",
	panel = require("atlas.issues.providers.gitlab.ui.panel"),
}

function M.setup()
	require("atlas.issues.providers.gitlab.highlights").setup()
end

function M.on_refresh()
	require("atlas.issues.providers.gitlab.api.service").clear_memory_cache()
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	return require("atlas.issues.providers.gitlab.ui.renderer").format_row(issue, is_child)
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	return require("atlas.issues.providers.gitlab.ui.renderer").cell_hl(row, col, ctx)
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	require("atlas.issues.providers.gitlab.api.users").get_user(on_done)
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	---@cast view AtlasGitLabIssuesViewConfig
	local issues_api = require("atlas.issues.providers.gitlab.api.issues")
	return issues_api.list_issues(view, {
		force_load = opts and opts.force_load == true or false,
		max_results = opts and opts.max_results or 50,
	}, function(issues, err)
		if err then
			on_done({}, nil, true, err)
			return
		end
		on_done(issues or {}, nil, true, nil)
	end)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(key, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.issues").get_issue(key, opts, on_done)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(raw: any, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(key, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.issues").get_description(key, opts, on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(issue, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").list_comments(tostring(issue.key or ""), opts, on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").list_history(tostring(issue.key or ""), opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[], reaction_options: IssueReactionOption[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local force = opts.force_refresh == true
	local notes = require("atlas.issues.providers.gitlab.api.notes")
	local key = tostring(issue.key or "")
	if key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local comments_result, events_result
	local first_err
	local pending = 2
	local handles = {}
	local cancelled = false

	local function finish()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if first_err and comments_result == nil and events_result == nil then
			on_done(nil, first_err)
			return
		end
		local comments = {}
		local raw = type(issue._raw) == "table" and issue._raw or {}
		local description = tostring(raw.description or "")
		if description ~= "" then
			table.insert(comments, {
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = description,
				created = raw.created_at or "",
			})
		end
		for _, c in ipairs(comments_result or {}) do
			table.insert(comments, c)
		end
		on_done({
			comments = comments,
			events = events_result or {},
			reaction_options = GITLAB_REACTION_OPTIONS,
		}, nil)
	end

	table.insert(handles, notes.list_comments(key, { force_load = force }, function(comments, err)
		if err then
			first_err = first_err or err
		else
			comments_result = comments
		end
		finish()
	end))

	table.insert(handles, notes.list_history(key, { force_load = force }, function(events, err)
		if err then
			first_err = first_err or err
		else
			events_result = events
		end
		finish()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					pcall(h.cancel)
				end
			end
		end,
	}
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").add(key, content, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(issue, parent, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").reply_in_discussion(key, parent, content, on_done)
end

---@param issue Issue
---@param comment_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment_id, content, on_done)
	local key = tostring(issue.key or "")
	if tostring(comment_id) == "__body__" then
		local raw = type(issue._raw) == "table" and issue._raw or {}
		local project = tonumber(raw.project_id)
		local iid = tonumber(raw.iid)
		if project == nil or iid == nil then
			on_done(nil, "Invalid issue")
			return nil
		end
		local service = require("atlas.issues.providers.gitlab.api.service")
		local endpoint = string.format("/projects/%d/issues/%d", project, iid)
		return service.request("PUT", endpoint, { description = content }, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			raw.description = content
			on_done({
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = content,
				created = raw.created_at or "",
			}, nil)
		end)
	end
	return require("atlas.issues.providers.gitlab.api.notes").edit(key, comment_id, content, on_done)
end

---@param issue Issue
---@param comment_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment_id, on_done)
	if tostring(comment_id) == "__body__" then
		on_done(false, "Cannot delete the issue description")
		return nil
	end
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").delete(key, comment_id, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, key, on_done)
	if tostring(comment.id) == "__body__" then
		on_done(false, "Reactions on the issue description are not supported on GitLab")
		return nil
	end
	local issue_key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").add_reaction(issue_key, comment.id, key, on_done)
end

---@param action_id string
---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.run_action(action_id, ctx, on_done)
	require("atlas.issues.providers.gitlab.actions").run(action_id, ctx, on_done)
end

---@param issue Issue|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil, err: string|nil)
function M.open_actions(issue, source, on_done)
	require("atlas.issues.providers.gitlab.actions").open({ issue = issue, source = source }, on_done)
end

---@param on_done fun(result: table|nil, err: string|nil)|nil
function M.search(on_done)
	require("atlas.issues.providers.gitlab.actions").run(
		"search",
		{ issue = nil, source = "main" },
		function(result, err)
			if on_done then
				on_done(result, err)
			end
		end
	)
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.gitlab.api.notifications")
	return notifications.fetch(opts or {}, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	return require("atlas.pulls.providers.gitlab.api.notifications").mark_read(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_done(id, on_done)
	return require("atlas.pulls.providers.gitlab.api.notifications").mark_done(id, on_done)
end

---@param opts GitLabCreateIssueOpts
---@param on_done fun(result: GitLabCreateIssueResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	return require("atlas.issues.providers.gitlab.api.issues").create_issue(opts, on_done)
end

---@return AtlasGitLabIssuesViewConfig[]
function M.views()
	local cfg = require("atlas.issues.providers.gitlab.api.service").gitlab_config()
	if cfg.views ~= nil then
		return cfg.views
	end
	return {
		{
			name = "Assigned",
			key = "1",
			scope = "assigned_to_me",
			state = "opened",
		},
		{
			name = "Created",
			key = "2",
			scope = "created_by_me",
			state = "opened",
		},
	}
end

return M
