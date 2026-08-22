local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()
local config = require("atlas.config")
local resolver = require("atlas.providers.resolve")
local notifications_api = require("atlas.providers.gitlab.notifications").new("issues")
local git = require("atlas.core.git")

---@class GitLabIssuesProvider : IssuesProvider
local M = {}

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

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.notes").list_history(tostring(issue.key or ""), opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
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

	return notes.list_conversation(key, { force_load = force }, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		local comments = {}
		local raw = issue._raw or {}
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
		vim.list_extend(comments, result.comments)
		on_done({
			comments = comments,
			events = result.events,
		}, nil)
	end)
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
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	local key = tostring(issue.key or "")
	if tostring(comment.id) == "__body__" then
		local raw = issue._raw or {}
		local project = tonumber(raw.project_id)
		local iid = tonumber(raw.iid)
		if project == nil or iid == nil then
			on_done(nil, "Invalid issue")
			return nil
		end
		local service = require("atlas.providers.gitlab.client").issues
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
	return require("atlas.issues.providers.gitlab.api.notes").edit(key, comment, content, on_done)
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
	return require("atlas.issues.providers.gitlab.api.notes").delete(key, comment, on_done)
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

---@param view AtlasGitLabIssuesViewConfig
---@return AtlasGitLabIssuesViewConfig
local function resolve_cur_repo(view)
	if not view.current_repo then
		return view
	end
	local root = git.repo_root()
	local info = git.local_repository(root)
	if not info then
		return view
	end
	local resolved = vim.tbl_extend("force", {}, view)
	resolved.project = info.slug
	resolved.scope = view.scope or "all"
	return resolved
end

---@return AtlasGitLabIssuesViewConfig[]
function M.views()
	local cfg = config.domain_options("gitlab", "issues") or {}
	local views = type(cfg.views) == "table" and #cfg.views > 0 and cfg.views
		or {
			{ name = "Assigned", key = "1", scope = "assigned_to_me", state = "opened" },
			{ name = "Created", key = "2", scope = "created_by_me", state = "opened" },
		}
	local resolved = {}
	for i, view in ipairs(views) do
		resolved[i] = resolve_cur_repo(view)
	end
	return resolved
end

local renderer = require("atlas.issues.providers.gitlab.ui.renderer")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("issues", "gitlab"))
	if path == nil then
		return nil, nil
	end

	local project_path, number, tail = path:match("^/(.-)/%-/issues/(%d+)(.*)$")
	local owner, repo = resolver.split_project(project_path)
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported GitLab issue URL"
		end
		return {
			provider = "gitlab",
			domain = "issues",
			entity = "issue",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = project_path,
			number = tonumber(number),
		}
	end

	return nil, "Unsupported GitLab URL. Expected a repository, issue, or merge request URL"
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
function M.search_view(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
		state = "all",
	}
end

---@param target AtlasTarget
---@return string|nil
function M.issue_key(target)
	if target.project_path and target.number then
		return string.format("%s#%d", target.project_path, target.number)
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
		provider = "gitlab",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		project_path = info.slug,
		number = number,
		url = string.format(
			"%s/%s/-/%s/%d",
			base_url,
			info.slug,
			entity == "pr" and "merge_requests" or "issues",
			number
		),
	}
end

---@param options table
---@return string[]
function M.repositories(options)
	local result = {}
	for _, view in ipairs(options.views or {}) do
		table.insert(result, view.project)
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
			fetch_user = require("atlas.issues.providers.gitlab.api.users").get_user,
			fetch_issues = M.fetch_issues,
			fetch_issue = M.fetch_issue,
			views = M.views,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			fetch_activity = M.fetch_activity,
			fetch_conversation = M.fetch_conversation,
			add_comment = M.add_comment,
			reply_comment = M.reply_comment,
			edit_comment = M.edit_comment,
			delete_comment = M.delete_comment,
			add_reaction = M.add_reaction,
		},
		notifications = {
			fetch = notifications_api.fetch,
			mark_read = notifications_api.mark_read,
			mark_done = notifications_api.mark_done,
		},
		actions = require("atlas.issues.providers.gitlab.actions"),
		ui = {
			setup = require("atlas.issues.providers.gitlab.highlights").setup,
			format_row = renderer.format_row,
			cell_hl = renderer.cell_hl,
			panel = require("atlas.issues.providers.gitlab.ui.panel"),
		},
	},
}
