---@class JiraIssueProject
---@field id string
---@field key string
---@field name string
---@field self string
---@field category table|nil

---@class JiraIssue : Issue
---@field project JiraIssueProject|nil
---@field priority string|nil

---@class JiraIssueCustomField
---@field name string
---@field formatted string
---@field hl_group string|nil
---@field display "chip"|"table"

---@class JiraIssueDetails : IssueDetails
---@field raw_description table|string|nil
---@field custom_fields JiraIssueCustomField[]

local actions = require("atlas.issues.providers.jira.actions")
local author_completion = require("atlas.providers.jira.completion.author")
local comments_api = require("atlas.issues.providers.jira.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.issues.providers.jira.ui.detail")
local highlights = require("atlas.issues.providers.jira.highlights")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local service = require("atlas.issues.providers.jira.api.service")
local users_api = require("atlas.issues.providers.jira.api.users")

---@param view IssuesViewConfig
---@return string
local function resolve_search(view)
	---@cast view AtlasJiraViewConfig
	return tostring(view.jql or view.search or "")
end

---@param target AtlasTarget
---@return AtlasJiraViewConfig
local function view_for_target(target)
	return { name = "Search", layout = "compact", jql = "key = " .. target.issue_key }
end

---@param target AtlasTarget
---@return IssueRef|nil
local function target_issue_ref(target)
	if target.issue_key then
		return { key = target.issue_key }
	end
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_issues(view, opts, on_done)
	local jql = resolve_search(view)
	if jql == "" then
		on_done({}, "Missing Jira view JQL")
		return nil
	end

	return issues_api.search_issues(jql, function(issues, err)
		if err or issues == nil then
			on_done({}, err or "Failed to fetch issues")
			return
		end
		on_done(issues, nil)
	end, {
		force_refresh = opts.force_refresh == true,
		pagelen = opts.pagelen,
	})
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_by_refs(refs, opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local quoted = {}
	for _, ref in ipairs(refs) do
		table.insert(quoted, string.format('"%s"', ref.key:gsub('"', '\\"')))
	end

	return issues_api.search_issues("key in (" .. table.concat(quoted, ",") .. ")", function(issues, err)
		if err or issues == nil then
			on_done({}, err or "Failed to fetch issues")
			return
		end
		on_done(issues, nil)
	end, {
		force_refresh = opts.force_refresh == true,
		pagelen = #refs,
	})
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_comment(issue, content, on_done)
	local issue_key = tostring(issue.key or "")
	return comments_api.add_comment(issue_key, content, nil, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function reply_comment(issue, parent, content, on_done)
	local issue_key = tostring(issue.key or "")
	return comments_api.add_comment(issue_key, content, { parent_id = tostring(parent.id) }, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_comment(issue, comment, content, on_done)
	local issue_key = tostring(issue.key or "")
	return comments_api.edit_comment(issue_key, tostring(comment.id), content, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local issue_key = tostring(issue.key or "")
	if issue_key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local force_refresh = opts.force_refresh == true

	return comments_api.get_comments_page(issue_key, 0, 100, function(comments, err)
		if err or comments == nil then
			on_done(nil, err or "Failed to fetch comments")
			return
		end
		local items = {}
		for _, comment in ipairs(comments) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		on_done(items, nil)
	end, { force_refresh = force_refresh })
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function delete_comment(issue, comment, on_done)
	local issue_key = tostring(issue.key or "")
	return comments_api.delete_comment(issue_key, tostring(comment.id), on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_activity(issue, opts, on_done)
	return issues_api.get_issue_history_page(tostring(issue.key or ""), 0, 100, function(page, err)
		if err or not page then
			on_done(nil, err or "Failed to fetch issue activity")
			return
		end
		on_done(page.values, nil)
	end, {
		force_refresh = opts and opts.force_refresh or false,
	})
end

---@return AtlasJiraViewConfig[]
local function views()
	local configured = (config.domain_options("jira", "issues") or {}).views
	if not configured or #configured == 0 then
		configured = {
			{
				name = "Issues",
				key = "1",
				jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
			},
		}
	end
	return configured
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = resolve_search,
	issue_ref = target_issue_ref,
	capabilities = {
		core = {
			fetch_user = users_api.get_myself,
			fetch_issues = fetch_issues,
			fetch_by_refs = fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			refresh = service.clear_memory_cache,
		},
		comments = {
			fetch_activity = fetch_activity,
			fetch_conversation = fetch_conversation,
			add_comment = add_comment,
			reply_comment = reply_comment,
			edit_comment = edit_comment,
			delete_comment = delete_comment,
			comment_completion = author_completion.for_issues,
		},
		actions = actions,
		ui = {
			setup = highlights.setup,
			detail = detail_ui,
		},
	},
}
