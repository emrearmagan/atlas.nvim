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
function M.fetch_description(key, opts, on_done) ---@diagnostic disable-line: unused-local
	local normalizer = require("atlas.issues.providers.github.api.mapper")
	local slug, number = normalizer.parse_key(tostring(key or ""))
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	local cli = require("atlas.issues.providers.github.api.cli")
	return cli.gh({
		"api", string.format("repos/%s/issues/%d", slug, number), "--jq", ".body",
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local body = type(result) == "string" and result:gsub("\n$", "") or ""
		on_done(body, nil)
	end)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(issue, opts, on_done)
	return require("atlas.issues.providers.github.api.comments").list(tostring(issue.key or ""), on_done, opts)
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(issue, parent, content, on_done) ---@diagnostic disable-line: unused-local
	-- GitHub issue comments are flat; reply is just a new comment.
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param issue Issue
---@param comment_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment_id, content, on_done)
	if tostring(comment_id) == "__body__" then
		local raw = type(issue._raw) == "table" and issue._raw or {}
		local slug = tostring(raw.slug or "")
		local number = tonumber(raw.number)
		if slug == "" or number == nil then
			on_done(nil, "Invalid issue")
			return nil
		end
		local cli = require("atlas.issues.providers.github.api.cli")
		return cli.gh({
			"issue", "edit", tostring(number), "--repo", slug, "--body", content,
		}, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
			raw.body = content
			on_done({
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = content,
				created = raw.created_at or "",
				reactions = raw.reactions,
			}, nil)
		end)
	end
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").edit(key, comment_id, content, on_done)
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
	return require("atlas.issues.providers.github.api.comments").delete(key, comment_id, on_done)
end

local GITHUB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[], reaction_options: IssueReactionOption[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local key = tostring(issue and issue.key or "")
	if key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local timeline = require("atlas.issues.providers.github.api.timeline")

	---@param description string
	local function build(result, description)
		local comments = {}
		if description ~= "" then
			local raw = type(issue._raw) == "table" and issue._raw or {}
			table.insert(comments, {
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = description,
				created = raw.created_at or "",
				reactions = raw.reactions,
			})
		end
		for _, c in ipairs(type(result.comments) == "table" and result.comments or {}) do
			table.insert(comments, c)
		end

		on_done({
			comments = comments,
			events = type(result.events) == "table" and result.events or {},
			reaction_options = GITHUB_REACTION_OPTIONS,
		}, nil)
	end

	return timeline.list_conversation(key, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end
		local raw = type(issue._raw) == "table" and issue._raw or {}
		local description = tostring(raw.body or "")
		if description ~= "" then
			build(result, description)
			return
		end

		M.fetch_description(key, opts, function(desc, _)
			build(result, tostring(desc or ""))
		end)
	end, { force_load = opts.force_refresh == true })
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, key, on_done)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local slug = tostring(raw.slug or "")
	local number = tonumber(raw.number)
	if slug == "" then
		on_done(false, "Invalid issue")
		return nil
	end

	local endpoint
	if tostring(comment.id) == "__body__" then
		if number == nil then
			on_done(false, "Invalid issue")
			return nil
		end
		endpoint = string.format("repos/%s/issues/%d/reactions", slug, number)
	else
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", slug, tostring(comment.id))
	end

	local cli = require("atlas.issues.providers.github.api.cli")
	return cli.api("POST", endpoint, { content = key }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	local timeline = require("atlas.issues.providers.github.api.timeline")
	return timeline.list_conversation(tostring(issue.key or ""), function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		on_done(type(result.events) == "table" and result.events or {}, nil)
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
---@param on_done fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	return require("atlas.issues.providers.github.api.issues").create_issue(opts, on_done)
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
