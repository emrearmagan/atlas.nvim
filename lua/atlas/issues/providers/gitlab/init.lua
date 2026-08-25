---@class GitLabIssue : Issue
---@field project_path string
---@field iid integer
---@field confidential boolean

---@class GitLabIssueDetails : IssueDetails, GitLabIssue

local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()
local config = require("atlas.config")
local notifications_api = require("atlas.providers.gitlab.notifications")
local git = require("atlas.core.git")

local M = {}

---@param view IssuesViewConfig
---@return string
function M.search_query(view)
	---@cast view AtlasGitLabIssuesViewConfig
	local parts = { "is:" .. tostring(view.state or "opened") }
	for _, field in ipairs({ "project", "scope", "labels", "milestone", "assignee_username", "author_username" }) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", field:gsub("_username$", ""), tostring(value)))
		end
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end

	local extra_keys = vim.tbl_keys(view.extra_params or {})
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", key, tostring(value)))
		end
	end
	return table.concat(parts, " ")
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

---@param refs IssueRef[]
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.issues").fetch_by_refs(refs, opts, function(issues, err)
		on_done(issues or {}, err)
	end)
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	return require("atlas.issues.providers.gitlab.api.issues").get_issue(ref.key, opts, on_done)
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
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
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
		local items = {}
		table.insert(items, {
			id = "description:" .. tostring(issue.key),
			kind = "description",
			created_at = issue.created_at or "",
			entity = issue,
		})
		for _, comment in ipairs(result.comments or {}) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		for index, entry in ipairs(result.events or {}) do
			table.insert(items, {
				id = table.concat({ "activity", entry.date or "", index }, ":"),
				kind = "activity",
				created_at = entry.date or "",
				entity = entry,
			})
		end
		on_done(items, nil)
	end)
end

---@param issue IssueDetails
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done)
	local key = tostring(issue.key or "")
	local issues_api = require("atlas.issues.providers.gitlab.api.issues")
	return issues_api.update_description(key, content, function(ok, err)
		if not ok then
			on_done(false, err)
			return
		end
		issue.description = content
		on_done(true, nil)
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
	return require("atlas.issues.providers.gitlab.api.notes").edit(key, comment, content, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").delete(key, comment, on_done)
end

---@param issue Issue
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, item, key, on_done)
	if item.kind == "description" then
		on_done(false, "Reactions on the issue description are not supported on GitLab")
		return nil
	end
	if item.kind ~= "comment" then
		on_done(false, "Reactions are only supported on comments")
		return nil
	end
	local comment = item.entity
	---@cast comment IssueComment
	local issue_key = tostring(issue.key or "")
	return require("atlas.issues.providers.gitlab.api.notes").add_reaction(issue_key, comment.id, key, on_done)
end

---@return AtlasGitLabIssuesViewConfig[]
function M.views()
	local cfg = config.domain_options("gitlab", "issues") or {}
	local views = cfg.views
	if not views or #views == 0 then
		views = {
			{ name = "Assigned", key = "1", scope = "assigned_to_me", state = "opened" },
			{ name = "Created", key = "2", scope = "created_by_me", state = "opened" },
		}
	end
	local repo
	for _, view in ipairs(views) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitlab" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(views) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].project = repo
			resolved[i].scope = view.scope or "all"
		end
	end
	return resolved
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
---@return IssueRef|nil
function M.issue_ref(target)
	if target.project_path and target.number then
		return { key = string.format("%s#%d", target.project_path, target.number) }
	end
end

return {
	views = M.views,
	search_view = M.search_view,
	issue_ref = M.issue_ref,
	capabilities = {
		core = {
			fetch_user = require("atlas.issues.providers.gitlab.api.users").get_user,
			search_query = M.search_query,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			update_description = M.update_description,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = require("atlas.providers.gitlab.completion.author").for_issues,
			fetch_activity = M.fetch_activity,
			fetch_conversation = M.fetch_conversation,
			add_comment = M.add_comment,
			reply_comment = M.reply_comment,
			edit_comment = M.edit_comment,
			delete_comment = M.delete_comment,
			add_reaction = M.add_reaction,
		},
		notifications = notifications_api,
		actions = require("atlas.issues.providers.gitlab.actions"),
		ui = {
			setup = require("atlas.issues.providers.gitlab.highlights").setup,
			detail = require("atlas.issues.providers.gitlab.ui.detail"),
		},
	},
}
