---@class ForgejoIssueLabel : IssueLabel
---@field id integer

---@class ForgejoIssueMilestone : IssueMilestone
---@field id integer
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class ForgejoIssue : Issue
---@field repo_full_name string
---@field number integer
---@field is_pinned boolean
---@field is_locked boolean
---@field due_date string|nil

---@class ForgejoIssueDetails : IssueDetails, ForgejoIssue
---@field labels ForgejoIssueLabel[]
---@field milestone ForgejoIssueMilestone|nil

require("atlas.issues.providers.forgejo.config")

local comments_api = require("atlas.issues.providers.forgejo.api.comments")
local issues_api = require("atlas.issues.providers.forgejo.api.issues")
local timeline_api = require("atlas.issues.providers.forgejo.api.timeline")
local notifications_api = require("atlas.providers.forgejo.notifications")
local git = require("atlas.core.git")

local M = {}
local REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param view IssuesViewConfig
---@return string
function M.search_query(view)
	---@cast view AtlasForgejoIssuesViewConfig
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

---@param view AtlasForgejoIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	return issues_api.list(view, opts, function(issues, next_page_token, is_last, err)
		if err then
			on_done({}, next_page_token, is_last, err)
			return
		end
		local pinned, rest = {}, {}
		for _, issue in ipairs(issues or {}) do
			---@cast issue ForgejoIssue
			table.insert(issue.is_pinned and pinned or rest, issue)
		end
		vim.list_extend(pinned, rest)
		on_done(pinned, next_page_token, is_last, nil)
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
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	return issues_api.get(ref, opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	---@cast issue ForgejoIssue
	return timeline_api.list(issue, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		if issue.description ~= "" then
			table.insert(items, {
				id = "description:" .. issue.key,
				kind = "description",
				created_at = issue.created_at or "",
				entity = issue,
			})
		end
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

---@param issue IssueDetails
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done)
	---@cast issue ForgejoIssueDetails
	return issues_api.update_issue(issue, { body = content }, function(updated, err)
		if err or not updated then
			on_done(false, err)
			return
		end
		---@cast updated ForgejoIssueDetails
		issue.description = updated.description
		on_done(true, nil)
	end)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	---@cast issue ForgejoIssue
	return timeline_api.list(issue, opts, function(result, err)
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
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	---@cast issue ForgejoIssue
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
	---@cast issue ForgejoIssue
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
	return comments_api.add_reaction(issue, comment_id, key, on_done)
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
	local repo
	for _, view in ipairs(views) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "forgejo" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(views) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].repo = repo
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasForgejoIssuesViewConfig
function M.search_view(target)
	return { name = "Search", layout = "compact", repo = target.repo_full_name, state = "all" }
end

---@param target AtlasTarget
---@return IssueRef|nil
function M.issue_ref(target)
	local slug = target.repo_full_name
	if slug and target.number then
		return { key = string.format("%s#%d", slug, target.number) }
	end
end

---@type IssuesCommentsCapability
local comments = {
	reaction_options = REACTION_OPTIONS,
	fetch_activity = M.fetch_activity,
	fetch_conversation = M.fetch_conversation,
	add_comment = function(issue, content, on_done)
		---@cast issue ForgejoIssue
		return comments_api.add(issue, content, on_done)
	end,
	edit_comment = M.edit_comment,
	delete_comment = function(issue, comment, on_done)
		---@cast issue ForgejoIssue
		return comments_api.delete(issue, comment.id, on_done)
	end,
	add_reaction = M.add_reaction,
	comment_completion = require("atlas.providers.forgejo.completion.author").for_issues,
}

return {
	views = M.views,
	search_view = M.search_view,
	issue_ref = M.issue_ref,
	capabilities = {
		core = {
			fetch_user = issues_api.fetch_user,
			search_query = M.search_query,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			update_description = M.update_description,
		},
		comments = comments,
		notifications = notifications_api,
		actions = require("atlas.issues.providers.forgejo.actions"),
		ui = {
			setup = require("atlas.issues.providers.forgejo.highlights").setup,
			detail = require("atlas.issues.providers.forgejo.ui.detail"),
		},
	},
}
