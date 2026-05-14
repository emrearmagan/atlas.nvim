local icons = require("atlas.ui.shared.icons")

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

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(key, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").list_comments(key, opts, on_done)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueHistoryEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(key, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").list_history(key, opts, on_done)
end

---@param key string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(key, content, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").add(key, content, on_done)
end

---@param key string
---@param _parent_id any
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(key, _parent_id, content, on_done)
	-- GitLab supports threaded discussions, but for simplicity replies are flat new notes.
	return require("atlas.issues.providers.gitlab.api.notes").add(key, content, on_done)
end

---@param key string
---@param comment_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(key, comment_id, content, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").edit(key, comment_id, content, on_done)
end

---@param key string
---@param comment_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(key, comment_id, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").delete(key, comment_id, on_done)
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
	require("atlas.issues.providers.gitlab.actions").run("search", { issue = nil, source = "main" }, function(result, err)
		if on_done then
			on_done(result, err)
		end
	end)
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
