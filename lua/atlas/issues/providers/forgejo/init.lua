require("atlas.issues.providers.forgejo.config")

local resolver = require("atlas.providers.resolve")
local request_scope = require("atlas.core.requests")
local comments_api = require("atlas.issues.providers.forgejo.api.comments")
local issues_api = require("atlas.issues.providers.forgejo.api.issues")
local timeline_api = require("atlas.issues.providers.forgejo.api.timeline")
local notifications_api = require("atlas.providers.forgejo.notifications").new("issues")

---@class ForgejoIssuesProvider : IssuesProvider
local M = {}
local REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param view AtlasForgejoIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
function M.fetch_issues(view, opts, on_done)
	return issues_api.list(view, opts, function(issues, next_page_token, is_last, err)
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

---@param issue IssueDetails
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
function M.fetch_conversation(issue, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return timeline_api.list(issue.key, opts, done)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		local reaction_targets = {}
		if issue.description ~= "" then
			local item = {
				id = "description:" .. issue.key,
				kind = "description",
				created_at = issue.created_at or "",
				entity = issue,
			}
			table.insert(items, item)
			table.insert(reaction_targets, {
				comment_id = "__body__",
				item = item,
			})
		end
		for _, comment in ipairs(result.comments) do
			local item = {
				id = "comment:" .. comment.id,
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			}
			table.insert(items, item)
			table.insert(reaction_targets, {
				comment_id = comment.id,
				item = item,
			})
		end
		for index, entry in ipairs(result.events) do
			table.insert(items, {
				id = table.concat({ "activity", entry.date or "", index }, ":"),
				kind = "activity",
				created_at = entry.date or "",
				entity = entry,
			})
		end

		local function load_reactions(index)
			local target = reaction_targets[index]
			if not target then
				on_done(items, nil)
				return
			end
			requests.run(function(done)
				return comments_api.list_reactions(issue.key, target.comment_id, done)
			end, function(reactions)
				if target.item.kind == "description" then
					issue.reactions = reactions
				else
					local comment = target.item.entity
					---@cast comment IssueComment
					comment.reactions = reactions
				end
				load_reactions(index + 1)
			end)
		end
		load_reactions(1)
	end)
	return requests
end

---@param issue IssueDetails
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done)
	return issues_api.update_issue(issue, { body = content }, function(updated, err)
		if err then
			on_done(false, err)
			return
		end
		issue.description = content
		issue._raw = updated._raw
		on_done(true, nil)
	end)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
function M.fetch_activity(issue, opts, on_done)
	return timeline_api.list(issue.key, opts, function(result, err)
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
	local requests = request_scope.new()
	requests.run(function(done)
		return comments_api.edit(issue.key, comment_id, content, done)
	end, function(updated_comment, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return comments_api.list_reactions(issue.key, comment_id, done)
		end, function(reactions)
			updated_comment.reactions = reactions
			on_done(updated_comment, nil)
		end)
	end)
	return requests
end

---@param issue Issue
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
function M.add_reaction(issue, item, key, on_done)
	local comment_id
	if item.kind == "description" then
		comment_id = "__body__"
	elseif item.kind == "comment" then
		local comment = item.entity
		---@cast comment IssueComment
		comment_id = comment.id
	else
		on_done(false, "This item does not support reactions")
		return nil
	end
	return comments_api.add_reaction(issue.key, comment_id, key, on_done)
end

---@return AtlasForgejoIssuesViewConfig[]
function M.views()
	local cfg = require("atlas.config").domain_options("forgejo", "issues") or {}
	local views = cfg.views or {}
	if #views == 0 then
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
	local path = resolver.path_for_base(parsed, resolver.configured_base("issues", "forgejo"))
	if path == nil then
		return nil, nil
	end
	local owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
	if not owner then
		return nil, nil
	end
	if not resolver.valid_tail(tail) then
		return nil, "Unsupported Forgejo issue URL"
	end
	return {
		provider = "forgejo",
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
---@return AtlasForgejoIssuesViewConfig
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
		provider = "forgejo",
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

---@param options AtlasForgejoIssuesConfig
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

local renderer = require("atlas.issues.providers.forgejo.ui.renderer")

---@type IssuesCommentsCapability
local comments = {
	reaction_options = REACTION_OPTIONS,
	fetch_activity = M.fetch_activity,
	fetch_conversation = M.fetch_conversation,
	add_comment = function(issue, content, on_done)
		return comments_api.add(issue.key, content, on_done)
	end,
	edit_comment = M.edit_comment,
	delete_comment = function(issue, comment, on_done)
		return comments_api.delete(issue.key, comment.id, on_done)
	end,
	add_reaction = M.add_reaction,
	comment_completion = function()
		return require("atlas.issues.providers.forgejo.completion.author").build_completion()
	end,
}

---@type AtlasNotificationsCapability
local notifications = {
	fetch = notifications_api.fetch,
	mark_read = notifications_api.mark_read,
	mark_done = notifications_api.mark_done,
}

local provider_actions = require("atlas.issues.providers.forgejo.actions")
local panel = require("atlas.issues.providers.forgejo.ui.panel")

return {
	resolve = M.resolve,
	search_view = M.search_view,
	issue_key = M.issue_key,
	target = M.target,
	repositories = M.repositories,
	capabilities = {
		core = {
			fetch_user = issues_api.fetch_user,
			fetch_issues = M.fetch_issues,
			fetch_issue = issues_api.get,
			update_description = M.update_description,
			views = M.views,
		},
		comments = comments,
		notifications = notifications,
		actions = provider_actions,
		ui = {
			setup = require("atlas.issues.providers.forgejo.highlights").setup,
			format_row = renderer.format_row,
			cell_hl = renderer.cell_hl,
			panel = panel,
		},
	},
}
