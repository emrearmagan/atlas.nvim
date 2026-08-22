require("atlas.issues.providers.gitea.config")

local api = require("atlas.issues.providers.gitea.api")
local resolver = require("atlas.providers.resolve")
local request_scope = require("atlas.core.requests")

local M = {}
local REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param view AtlasGiteaForgejoIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
function M.fetch_issues(view, opts, on_done)
	return api.issues.list(view, opts, function(issues, next_page_token, is_last, err)
		if err then
			on_done({}, next_page_token, is_last, err)
			return
		end
		local pinned, rest = {}, {}
		for _, issue in ipairs(issues) do
			table.insert(issue.is_pinned and pinned or rest, issue)
		end
		vim.list_extend(pinned, rest)
		on_done(pinned, next_page_token, is_last, err)
	end)
end

---@param issue Issue
---@param opts table|nil
---@param on_done fun(result: table|nil, err: string|nil)
function M.fetch_conversation(issue, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return api.timeline.list(issue.key, opts, done)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local comments = {}
		local raw = issue._raw
		local description = raw.description
		if description ~= "" then
			table.insert(comments, {
				id = "__body__",
				url = issue.url,
				author = issue.reporter,
				body = description,
				created = raw.created_at,
				reactions = raw.reactions,
			})
		end
		vim.list_extend(comments, result.comments)

		local function load_reactions(index)
			local comment = comments[index]
			if not comment then
				on_done({ comments = comments, events = result.events }, nil)
				return
			end
			requests.run(function(done)
				return api.comments.list_reactions(issue.key, comment.id, done)
			end, function(reactions)
				comment.reactions = reactions
				if comment.id == "__body__" then
					raw.reactions = reactions
				end
				load_reactions(index + 1)
			end)
		end
		load_reactions(1)
	end)
	return requests
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
function M.fetch_activity(issue, opts, on_done)
	return api.timeline.list(issue.key, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(result.events, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
function M.edit_comment(issue, comment, content, on_done)
	local comment_id = comment.id
	if comment_id ~= "__body__" then
		local requests = request_scope.new()
		requests.run(function(done)
			return api.comments.edit(issue.key, comment_id, content, done)
		end, function(updated_comment, err)
			if err then
				on_done(nil, err)
				return
			end
			requests.run(function(done)
				return api.comments.list_reactions(issue.key, comment_id, done)
			end, function(reactions)
				updated_comment.reactions = reactions
				on_done(updated_comment, nil)
			end)
		end)
		return requests
	end
	return api.issues.update_issue(issue, { body = content }, function(updated, err)
		if err then
			on_done(nil, err)
			return
		end
		local reactions = issue._raw.reactions
		issue._raw = updated._raw
		issue._raw.reactions = reactions
		on_done({
			id = "__body__",
			url = updated.url,
			author = updated.reporter,
			body = content,
			created = updated._raw.created_at,
			reactions = reactions,
		}, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
function M.add_reaction(issue, comment, key, on_done)
	return api.comments.add_reaction(issue.key, comment.id, key, on_done)
end

---@return AtlasGiteaForgejoIssuesViewConfig[]
function M.views()
	local cfg = require("atlas.config").domain_options("gitea", "issues") or {}
	local views = cfg.views
	if views == nil then
		views = {
			{ name = "Assigned", key = "1", scope = "assigned", state = "open" },
			{ name = "Created", key = "2", scope = "created", state = "open" },
		}
	end
	return views
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if not parsed then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("issues", "gitea"))
	if path == nil then
		return nil, nil
	end
	local owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
	if not owner then
		return nil, nil
	end
	if not resolver.valid_tail(tail) then
		return nil, "Unsupported Gitea/Forgejo issue URL"
	end
	return {
		provider = "gitea",
		domain = "issues",
		entity = "issue",
		url = value,
		host = parsed.host,
		owner = owner,
		repo = repo,
		project_path = owner .. "/" .. repo,
		number = tonumber(number),
	}
end

---@param target AtlasTarget
---@return AtlasGiteaForgejoIssuesViewConfig
function M.search_view(target)
	return { name = "Search", layout = "compact", repo = target.project_path, state = "all" }
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
	local owner, repo = info.slug:match("^([^/]+)/([^/]+)$")
	return {
		provider = "gitea",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		project_path = info.slug,
		number = number,
		url = string.format("%s/%s/%s/%d", base_url, info.slug, entity == "pr" and "pulls" or "issues", number),
	}
end

---@param options AtlasGiteaForgejoIssuesConfig
---@return string[]
function M.repositories(options)
	local result, seen = {}, {}
	---@param value string|nil
	local function add(value)
		local repo = vim.trim(value or "")
		if repo ~= "" and not seen[repo] then
			seen[repo] = true
			table.insert(result, repo)
		end
	end

	for _, view in ipairs(options.views or {}) do
		add(view.repo)
	end

	local bookmark_repos = {}
	for _, bookmark in pairs((options.bookmarks or {}).items or {}) do
		local repo = vim.trim(bookmark.repo or "")
		if repo ~= "" then
			table.insert(bookmark_repos, repo)
		end
	end
	table.sort(bookmark_repos)
	for _, repo in ipairs(bookmark_repos) do
		add(repo)
	end
	return result
end

local renderer = require("atlas.issues.providers.gitea.ui.renderer")

---@type IssuesCommentsCapability
local comments = {
	reaction_options = REACTION_OPTIONS,
	fetch_activity = M.fetch_activity,
	fetch_conversation = M.fetch_conversation,
	add_comment = function(issue, content, on_done)
		return api.comments.add(issue.key, content, on_done)
	end,
	edit_comment = M.edit_comment,
	delete_comment = function(issue, comment, on_done)
		local comment_id = comment.id
		if comment_id == "__body__" then
			on_done(false, "Cannot delete the issue description")
			return nil
		end
		return api.comments.delete(issue.key, comment_id, on_done)
	end,
	add_reaction = M.add_reaction,
	comment_completion = function()
		return require("atlas.issues.providers.gitea.completion.author").build_completion()
	end,
}

---@type AtlasNotificationsCapability
local notifications = {
	fetch = api.notifications.fetch,
	mark_read = api.notifications.mark_read,
	mark_done = api.notifications.mark_done,
}

return {
	resolve = M.resolve,
	search_view = M.search_view,
	issue_key = M.issue_key,
	target = M.target,
	repositories = M.repositories,
	capabilities = {
		core = {
			fetch_user = api.issues.fetch_user,
			fetch_issues = M.fetch_issues,
			fetch_issue = api.issues.get,
			views = M.views,
		},
		comments = comments,
		notifications = notifications,
		actions = require("atlas.issues.providers.gitea.actions"),
		ui = {
			setup = require("atlas.issues.providers.gitea.highlights").setup,
			format_row = renderer.format_row,
			cell_hl = renderer.cell_hl,
			panel = require("atlas.issues.providers.gitea.ui.panel"),
		},
	},
}
