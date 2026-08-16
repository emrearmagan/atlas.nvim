---@class GitHubIssuesProvider : IssuesProvider
local M = {}

local resolver = require("atlas.providers.resolve")
local request_scope = require("atlas.core.requests")
local issue_cache = require("atlas.issues.providers.github.api.cache")
local notifications_api = require("atlas.providers.github.notifications").new("issues")

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
		local sorted = vim.list_extend({}, pinned)
		vim.list_extend(sorted, rest)

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
---@param on_done fun(raw: any, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_description(key, on_done)
	local normalizer = require("atlas.issues.providers.github.api.mapper")
	local slug, number = normalizer.parse_key(tostring(key or ""))
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	local cli = require("atlas.providers.github.client").issues
	return cli.gh({
		"api",
		string.format("repos/%s/issues/%d", slug, number),
		"--jq",
		".body",
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
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	if tostring(comment.id) == "__body__" then
		local raw = issue._raw or {}
		local slug = tostring(raw.slug or "")
		local number = tonumber(raw.number)
		if slug == "" or number == nil then
			on_done(nil, "Invalid issue")
			return nil
		end
		local cli = require("atlas.providers.github.client").issues
		return cli.gh({
			"issue",
			"edit",
			tostring(number),
			"--repo",
			slug,
			"--body",
			content,
		}, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			issue_cache.invalidate(tostring(issue.key or ""))
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
	return require("atlas.issues.providers.github.api.comments").edit(key, tostring(comment.id), content, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	if tostring(comment.id) == "__body__" then
		on_done(false, "Cannot delete the issue description")
		return nil
	end
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").delete(key, tostring(comment.id), on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local key = tostring(issue and issue.key or "")
	if key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local timeline = require("atlas.issues.providers.github.api.timeline")
	local requests = request_scope.new()

	---@param result table
	---@param description string
	local function finish(result, description)
		local raw = issue._raw or {}
		local comments = {}
		if description ~= "" then
			table.insert(comments, {
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = description,
				created = raw.created_at or "",
				reactions = raw.reactions,
			})
		end
		vim.list_extend(comments, type(result.comments) == "table" and result.comments or {})

		on_done({
			comments = comments,
			events = result.events or {},
		}, nil)
	end

	requests.run(function(done)
		return timeline.list_conversation(key, done, { force_load = opts.force_refresh == true })
	end, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end

		local raw = issue._raw or {}
		local description = tostring(raw.body or "")
		if description ~= "" then
			finish(result, description)
			return
		end

		requests.run(function(done)
			return fetch_description(key, done)
		end, function(body)
			finish(result, tostring(body or ""))
		end)
	end)
	return requests
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, key, on_done)
	local raw = issue._raw or {}
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

	local cli = require("atlas.providers.github.client").issues
	return cli.api("POST", endpoint, { content = key }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		issue_cache.invalidate(tostring(issue.key or ""))
		on_done(true, nil)
	end)
end

---@param issue Issue
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
		on_done(result.events, nil)
	end, { force_load = opts and opts.force_load == true or false })
end

---@return AtlasGitHubIssuesViewConfig[]
function M.views()
	local cli = require("atlas.providers.github.client").issues
	local cfg = cli.github_config()
	local views = cfg.views or {
		{
			name = "Assigned",
			key = "1",
			search = "assignee:@me is:open",
		},
	}
	return require("atlas.ui.shared.bookmarks_view").append_to_views(views, cfg.bookmarks, "S", "Search")
end

local renderer = require("atlas.issues.providers.github.ui.renderer")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil or parsed.host ~= "github.com" then
		return nil, nil
	end

	local owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported GitHub issue URL"
		end
		return {
			provider = "github",
			domain = "issues",
			entity = "issue",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			number = tonumber(number),
		}
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, or pull request URL"
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
function M.search_view(target)
	return {
		name = "Search",
		layout = "compact",
		search = string.format(
			"repo:%s/%s %s is:issue",
			target.owner,
			target.repo,
			target.number and tostring(target.number) or ""
		),
	}
end

---@param target AtlasTarget
---@return string|nil
function M.issue_key(target)
	if target.owner and target.repo and target.number then
		return string.format("%s/%s#%d", target.owner, target.repo, target.number)
	end
end

---@param info AtlasGitRemoteInfo
---@param domain AtlasDomain
---@param entity AtlasEntity
---@param number integer
---@param base_url string
---@return AtlasTarget
function M.target(info, domain, entity, number, base_url)
	local owner, repo = info.slug:match("^(.+)/([^/]+)$")
	return {
		provider = "github",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		number = number,
		url = string.format("%s/%s/%s/%s/%d", base_url, owner, repo, entity == "pr" and "pull" or "issues", number),
	}
end

---@param options table
---@return string[]
function M.repositories(options)
	local result = {}
	for _, view in ipairs(options.views or {}) do
		for slug in tostring(view.search or ""):gmatch("repo:([%w._/-]+)") do
			table.insert(result, slug)
		end
	end
	return result
end

return {
	resolve = M.resolve,
	search_view = M.search_view,
	issue_key = M.issue_key,
	target = M.target,
	repositories = M.repositories,
	capabilities = {
		core = {
			fetch_user = require("atlas.issues.providers.github.api.users").get_user,
			fetch_issues = M.fetch_issues,
			fetch_issue = M.fetch_issue,
			views = M.views,
		},
		comments = {
			reaction_options = require("atlas.ui.shared.emojis").github(),
			fetch_activity = M.fetch_activity,
			fetch_conversation = M.fetch_conversation,
			add_comment = M.add_comment,
			edit_comment = M.edit_comment,
			delete_comment = M.delete_comment,
			add_reaction = M.add_reaction,
		},
		notifications = {
			fetch = notifications_api.fetch,
			mark_read = notifications_api.mark_read,
			mark_done = notifications_api.mark_done,
		},
		actions = require("atlas.issues.providers.github.actions"),
		ui = {
			setup = require("atlas.issues.providers.github.highlights").setup,
			render = require("atlas.issues.providers.github.ui.main").render,
			format_row = renderer.format_row,
			cell_hl = renderer.cell_hl,
			issue_popup_content = renderer.issue_popup_content,
			panel = require("atlas.issues.providers.github.ui.panel"),
		},
	},
}
