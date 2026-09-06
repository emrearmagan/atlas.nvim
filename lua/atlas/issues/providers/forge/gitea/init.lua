---@class GiteaIssueLabel : IssueLabel
---@field id integer

---@class GiteaIssueMilestone : IssueMilestone
---@field id integer
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class GiteaIssue : Issue
---@field number integer
---@field repo_full_name string
---@field is_pinned boolean
---@field is_locked boolean
---@field content_version integer|nil
---@field due_date string|nil

---@class GiteaIssueDetails : IssueDetails
---@field labels GiteaIssueLabel[]
---@field milestone GiteaIssueMilestone|nil

require("atlas.issues.providers.forge.gitea.config")

local api = require("atlas.issues.providers.forge.gitea.api")
local comments_api = api.comments
local issues_api = api.issues
local timeline_api = api.timeline
local notifications_api = require("atlas.providers.forge.gitea.api").notifications
local git = require("atlas.core.git")

local M = {}
local REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param view IssuesViewConfig
---@return string
function M.resolve_search(view)
	---@cast view AtlasGiteaIssuesViewConfig
	local repo = vim.trim(view.repo or "")
	local parts = { repo ~= "" and ("repo:" .. repo) or "type:issues", "is:" .. (view.state or "open") }
	local scope = view.scope or ""
	if scope ~= "" and scope ~= "all" then
		table.insert(parts, "scope:" .. scope)
	end
	local labels = vim.trim(view.labels or "")
	if labels ~= "" then
		table.insert(parts, "labels:" .. labels)
	end
	local extra_keys = vim.tbl_keys(view.extra_params or {})
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			table.insert(parts, key .. ":" .. tostring(value))
		end
	end
	local search = vim.trim(view.search or "")
	if search ~= "" then
		table.insert(parts, search)
	end
	return table.concat(parts, " ")
end

---@param view AtlasGiteaIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	return issues_api.list(view, opts, function(page, err)
		if err then
			on_done({ items = {} }, err)
			return
		end
		local pinned, rest = {}, {}
		for _, issue in ipairs(page.items) do
			---@cast issue GiteaIssue
			table.insert(issue.is_pinned and pinned or rest, issue)
		end
		vim.list_extend(pinned, rest)
		page.items = pinned
		on_done(page, nil)
	end)
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	return issues_api.fetch_by_refs(refs, opts, function(issues, err)
		on_done(issues or {}, err)
	end)
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	return issues_api.get(ref, opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	---@cast issue GiteaIssue
	return timeline_api.list(issue, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, comment in ipairs(result.comments) do
			table.insert(items, {
				id = "comment:" .. comment.id,
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
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
		-- TODO: Figure out how the fuck to load reactions without N+1 requests.
		on_done(items, nil)
	end)
end

---@param issue Issue
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done)
	---@cast issue GiteaIssue
	return issues_api.update_issue(issue, { body = content }, function(updated, err)
		if err or not updated then
			on_done(false, err or "Invalid Gitea issue response")
			return
		end
		on_done(true, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	---@cast issue GiteaIssue
	return comments_api.edit(issue, comment.id, content, function(updated_comment, err)
		if err then
			on_done(nil, err)
			return
		end
		updated_comment.reactions = comment.reactions
		on_done(updated_comment, nil)
	end)
end

---@param issue Issue
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, item, key, on_done)
	---@cast issue GiteaIssue
	if item.kind == "comment" then
		---@type IssueComment
		local comment = item.entity
		return comments_api.add_reaction(issue, comment.id, key, on_done)
	end
	on_done(false, "This item does not support reactions")
	return nil
end

---@return AtlasGiteaIssuesViewConfig[]
function M.views()
	local cfg = require("atlas.config").domain_options("gitea", "issues") or {}
	local views = cfg.views or {}
	if #views == 0 then
		views = {
			{ name = "Assigned", key = "1", scope = "assigned", state = "open" },
			{ name = "Created", key = "2", scope = "created", state = "open" },
		}
	end
	local repo
	for _, view in ipairs(views) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitea" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for index, view in ipairs(views) do
		resolved[index] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[index].repo = repo
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasGiteaIssuesViewConfig
function M.view_for_target(target)
	return { name = "Search", layout = "compact", repo = target.repo_full_name, state = "all" }
end

---@param target AtlasTarget
---@return IssueRef|nil
function M.issue_ref(target)
	local repo = target.repo_full_name
	if repo and target.number then
		return { key = string.format("%s#%d", repo, target.number) }
	end
end

---@type IssuesCommentsCapability
local comments = {
	reaction_options = REACTION_OPTIONS,
	fetch_conversation = M.fetch_conversation,
	add_comment = function(issue, content, on_done)
		---@cast issue GiteaIssue
		return comments_api.add(issue, content, on_done)
	end,
	edit_comment = M.edit_comment,
	delete_comment = function(issue, comment, on_done)
		---@cast issue GiteaIssue
		return comments_api.delete(issue, comment.id, on_done)
	end,
	add_reaction = M.add_reaction,
	comment_completion = require("atlas.providers.forge.completion.author").for_issues,
}

return {
	views = M.views,
	view_for_target = M.view_for_target,
	resolve_search = M.resolve_search,
	issue_ref = M.issue_ref,
	capabilities = {
		core = {
			fetch_user = issues_api.fetch_user,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			update_description = M.update_description,
		},
		comments = comments,
		notifications = notifications_api,
		actions = require("atlas.issues.providers.forge.actions.registry").new("gitea", issues_api),
		ui = {
			detail = require("atlas.issues.providers.forge.ui.detail").new("gitea"),
		},
	},
}
