local icons = require("atlas.ui.shared.icons")

---@class GitHubIssuesProvider : IssuesProvider
local M = {
	id = "github",
	name = "GitHub",
	icon = icons.pulls_provider("github", "provider"),
	hl_group = "AtlasGHIssuesTheme",
	panel = require("atlas.issues.providers.github.ui.panel"),
}

function M.setup()
	require("atlas.issues.providers.github.highlights").setup()
end

function M.on_refresh()
	-- nothing to clear globally; per-key caches expire naturally
end

---@param issue_groups IssuesGroup[]
---@param layout "plain"|"compact"
---@param opts { width: integer }
---@return IssuesMainRenderResult
function M.render(issue_groups, layout, opts)
	return require("atlas.issues.providers.github.ui.main").render(issue_groups, layout, opts)
end

---@param issue Issue
---@param is_child boolean
function M.format_row(issue, is_child)
	return require("atlas.issues.providers.github.ui.renderer").format_row(issue, is_child)
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
function M.cell_hl(row, col, ctx)
	return require("atlas.issues.providers.github.ui.renderer").cell_hl(row, col, ctx)
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	require("atlas.issues.providers.github.api.users").get_user(on_done)
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	---@cast view AtlasGitHubIssuesViewConfig
	local search = tostring(view and view.search or "")
	if search == "" then
		on_done({}, nil, true, "Missing search query for GitHub view")
		return nil
	end

	local issues_api = require("atlas.issues.providers.github.api.issues")
	local limit = opts and opts.max_results or 50
	local layout = tostring((view and view.layout) or (opts and opts.layout) or "plain")
	return issues_api.search_issues(search, function(issues, err)
		if err then
			on_done({}, nil, true, err)
			return
		end

		local pinned, rest = {}, {}
		for _, issue in ipairs(issues or {}) do
			if issue.is_pinned == true then
				table.insert(pinned, issue)
			else
				table.insert(rest, issue)
			end
		end
		local sorted = {}
		for _, i in ipairs(pinned) do
			table.insert(sorted, i)
		end
		for _, i in ipairs(rest) do
			table.insert(sorted, i)
		end

		on_done(sorted, nil, true, nil)
	end, {
		force_load = opts and opts.force_load == true or false,
		limit = limit,
		with_relationships = layout ~= "compact",
	})
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(key, opts, on_done)
	opts = opts or {}
	local api_opts = {}
	for k, v in pairs(opts) do
		api_opts[k] = v
	end
	if api_opts.layout == "compact" then
		api_opts.with_relationships = false
	end
	return require("atlas.issues.providers.github.api.issues").get_issue(key, on_done, api_opts)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(raw: any, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(key, opts, on_done)
	-- GitHub stores body on the issue payload; refresh the issue and return body.
	return require("atlas.issues.providers.github.api.issues").get_issue(key, function(issue, err)
		if err or issue == nil then
			on_done(nil, err)
			return
		end
		local raw = type(issue._raw) == "table" and issue._raw or {}
		on_done(tostring(raw.body or ""), nil)
	end, opts)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(key, opts, on_done)
	return require("atlas.issues.providers.github.api.comments").list(key, on_done, opts)
end

---@param key string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(key, content, on_done)
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param key string
---@param parent_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(key, parent_id, content, on_done)
	-- GitHub issue comments are flat; reply is just a new comment.
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param key string
---@param comment_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(key, comment_id, content, on_done)
	return require("atlas.issues.providers.github.api.comments").edit(key, comment_id, content, on_done)
end

---@param key string
---@param comment_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(key, comment_id, on_done)
	return require("atlas.issues.providers.github.api.comments").delete(key, comment_id, on_done)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueHistoryEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(key, opts, on_done)
	local timeline = require("atlas.issues.providers.github.api.timeline")
	return timeline.list(key, function(events, err)
		if err or type(events) ~= "table" then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, ev in ipairs(events) do
			if ev.event ~= "commented" then
				table.insert(entries, {
					id = tostring(ev.date or ""),
					created = ev.date,
					author = ev.actor,
					items = {
						{
							field = ev.event,
							label_name = ev.label_name,
							label_color = ev.label_color,
							assignee_login = ev.assignee_login,
							milestone_title = ev.milestone_title,
							rename_from = ev.rename_from,
							rename_to = ev.rename_to,
							commit_id = ev.commit_id,
							source_title = ev.source_title,
							source_url = ev.source_url,
						},
					},
				})
			end
		end

		on_done(entries, nil)
	end, { force_load = opts and opts.force_load == true or false })
end

---@param action_id string
---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.run_action(action_id, ctx, on_done)
	require("atlas.issues.providers.github.actions").run(action_id, ctx, on_done)
end

---@param issue Issue|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil, err: string|nil)
function M.open_actions(issue, source, on_done)
	require("atlas.issues.providers.github.actions").open({ issue = issue, source = source }, on_done)
end

---@param on_done fun(result: table|nil, err: string|nil)|nil
function M.search(on_done)
	require("atlas.issues.providers.github.actions").run(
		"search",
		{ issue = nil, source = "main" },
		function(result, err)
			if on_done then
				on_done(result, err)
			end
		end
	)
end

---@param opts GitHubCreateIssueOpts
---@param on_done fun(result: GitHubCreateIssueResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	return require("atlas.issues.providers.github.api.issues").create_issue(opts, on_done)
end

---@param issue Issue
---@param on_done fun(is_subscribed: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.toggle_subscription(issue, on_done)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local node_id = tostring(raw.node_id or "")
	if node_id == "" then
		vim.schedule(function()
			on_done(nil, "Missing issue node id")
		end)
		return nil
	end
	local next_state = issue.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
	local gql =
		"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on Issue { viewerSubscription } } } }"
	local cli = require("atlas.issues.providers.github.api.cli")
	return cli.gh(
		{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
		function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			issue.is_subscribed = (next_state == "SUBSCRIBED")
			on_done(issue.is_subscribed, nil)
		end
	)
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.github.api.notifications")
	local merged = vim.tbl_extend("force", { all = true, per_page = 100 }, opts or {})
	return notifications.fetch(merged, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	return require("atlas.pulls.providers.github.api.notifications").mark_read(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_done(id, on_done)
	return require("atlas.pulls.providers.github.api.notifications").mark_done(id, on_done)
end

---@return AtlasGitHubIssuesViewConfig[]
function M.views()
	local cli = require("atlas.issues.providers.github.api.cli")
	local views = cli.github_config().views
	if views ~= nil then
		return views
	end
	return {
		{
			name = "Assigned",
			key = "1",
			search = "assignee:@me is:open",
		},
	}
end

return M
