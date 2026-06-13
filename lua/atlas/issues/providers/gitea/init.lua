local icons = require("atlas.ui.shared.icons")

---@class GiteaIssuesProvider : IssuesProvider
local M = {
	id = "gitea",
	name = "Gitea",
	icon = icons.issues("issue"),
	hl_group = "AtlasGiteaIssuesTheme",
	panel = require("atlas.issues.providers.gitea.ui.panel"),
}

function M.setup()
	require("atlas.issues.providers.gitea.highlights").setup()
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	return require("atlas.issues.providers.gitea.ui.renderer").format_row(issue, is_child)
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	return require("atlas.issues.providers.gitea.ui.renderer").cell_hl(row, col, ctx)
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	require("atlas.issues.providers.gitea.api.users").get_user(on_done)
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	---@cast view AtlasGiteaIssuesViewConfig
	local issues_api = require("atlas.issues.providers.gitea.api.issues")
	local limit = opts and opts.max_results or 50
	return issues_api.list_issues(view, {
		force_load = opts and opts.force_load == true or false,
		max_results = limit,
	}, function(issues, err)
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
	end)
end

---@param key string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(key, opts, on_done)
	return require("atlas.issues.providers.gitea.api.issues").get_issue(key, opts, on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(issue, opts, on_done)
	return require("atlas.issues.providers.gitea.api.comments").list(tostring(issue.key or ""), on_done, opts)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	local timeline = require("atlas.issues.providers.gitea.api.timeline")
	return timeline.list_conversation(tostring(issue.key or ""), function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		on_done(type(result.events) == "table" and result.events or {}, nil)
	end, { force_load = opts and opts.force_load == true or false })
end

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

	local timeline = require("atlas.issues.providers.gitea.api.timeline")
	return timeline.list_conversation(key, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end

		local comments = {}
		local raw = type(issue._raw) == "table" and issue._raw or {}
		local description = tostring(raw.body or "")
		if description ~= "" then
			table.insert(comments, {
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = description,
				created = raw.created_at or "",
			})
		end
		for _, c in ipairs(type(result.comments) == "table" and result.comments or {}) do
			table.insert(comments, c)
		end

		on_done({
			comments = comments,
			events = type(result.events) == "table" and result.events or {},
			reaction_options = nil,
		}, nil)
	end, { force_load = opts.force_refresh == true })
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitea.api.comments").add(key, content, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(issue, parent, content, on_done) ---@diagnostic disable-line: unused-local
	-- Gitea issue comments are flat; reply is just a new comment
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitea.api.comments").add(key, content, on_done)
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
		local cli = require("atlas.issues.providers.gitea.api.cli")
		local endpoint = string.format("/repos/%s/issues/%d", slug, number)
		local body = vim.json.encode({ body = content })
		return cli.api("PATCH", endpoint, body, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			cli.delete_mem(string.format("gitea_issues:get:%s#%d", slug, number))
			raw.body = content
			on_done({
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = content,
				created = raw.created_at or "",
			}, nil)
		end)
	end
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitea.api.comments").edit(key, comment_id, content, on_done)
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
	return require("atlas.issues.providers.gitea.api.comments").delete(key, comment_id, on_done)
end

---@param action_id string
---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.run_action(action_id, ctx, on_done)
	require("atlas.issues.providers.gitea.actions").run(action_id, ctx, on_done)
end

---@param issue Issue|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil, err: string|nil)
function M.open_actions(issue, source, on_done)
	require("atlas.issues.providers.gitea.actions").open({ issue = issue, source = source }, on_done)
end

---@return AtlasGiteaIssuesViewConfig[]
function M.views()
	local cli = require("atlas.issues.providers.gitea.api.cli")
	local views = cli.gitea_config().views
	if views ~= nil then
		return views
	end
	return {
		{
			name = "Assigned",
			key = "1",
			filter = { assigned = true, state = "open" },
		},
		{
			name = "Created",
			key = "2",
			filter = { created = true, state = "open" },
		},
	}
end

return M
