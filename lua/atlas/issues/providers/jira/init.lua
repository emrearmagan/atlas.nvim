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

---@class JiraIssueDetails : IssueDetails, JiraIssue
---@field raw_description table|string|nil
---@field custom_fields JiraIssueCustomField[]

local M = {}

---@param view IssuesViewConfig
---@return string
function M.search_query(view)
	---@cast view AtlasJiraViewConfig
	return tostring(view.jql or view.search or "")
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
local function search_view(target)
	return { name = "Search", layout = "compact", jql = "key = " .. target.issue_key }
end

---@param target AtlasTarget
---@return IssueRef|nil
local function target_issue_ref(target)
	if target.issue_key then
		return { key = target.issue_key }
	end
end

function M.on_refresh()
	local service = require("atlas.issues.providers.jira.api.service")
	service.clear_memory_cache()
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	local jql = M.search_query(view)
	if jql == "" then
		on_done({}, nil, true, "Missing Jira view JQL")
		return nil
	end

	return issues_api.search_issues(jql, function(page, err)
		if err or page == nil then
			on_done({}, nil, true, err or "Failed to fetch issues")
			return
		end

		on_done(page.issues or {}, page.nextPageToken, page.isLast == true, nil)
	end, {
		force_load = opts and opts.force_load == true or false,
		next_page_token = opts and opts.next_page_token or nil,
		max_results = opts and opts.max_results or nil,
	})
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local quoted = {}
	for _, ref in ipairs(refs) do
		table.insert(quoted, string.format('"%s"', ref.key:gsub('"', '\\"')))
	end

	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.search_issues("key in (" .. table.concat(quoted, ",") .. ")", function(page, err)
		on_done(page and page.issues or {}, err)
	end, {
		force_load = opts and opts.force_load == true,
		max_results = #refs,
	})
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.get_issue(ref.key, on_done, { force_load = opts and opts.force_load == true })
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(issue, opts, on_done)
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	local COMMENTS_PAGE_SIZE = 100

	return comments_api.get_comments_page(tostring(issue.key or ""), 0, COMMENTS_PAGE_SIZE, on_done, {
		force_load = opts and opts.force_load or false,
	})
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.add_comment(issue_key, content, nil, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(issue, parent, content, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.add_comment(issue_key, content, { parent_id = tostring(parent.id) }, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.edit_comment(issue_key, tostring(comment.id), content, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local issue_key = tostring(issue and issue.key or "")
	if issue_key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local force = opts.force_refresh == true

	return fetch_comments(issue, { force_load = force }, function(comments, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, comment in ipairs(comments or {}) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		on_done(items, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.delete_comment(issue_key, tostring(comment.id), on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.get_issue_history_page(tostring(issue.key or ""), 0, 100, function(page, err)
		if err or not page then
			on_done(nil, err)
			return
		end
		on_done(page.values or {}, nil)
	end, {
		force_load = opts and opts.force_load or false,
	})
end

---@return AtlasJiraViewConfig[]
function M.views()
	local cfg = require("atlas.issues.providers.jira.api.config").jira_config()
	local views = type(cfg.views) == "table" and #cfg.views > 0 and cfg.views
		or {
			{
				name = "Issues",
				key = "1",
				jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
			},
		}
	return views
end

return {
	search_view = search_view,
	issue_ref = target_issue_ref,
	capabilities = {
		core = {
			fetch_user = require("atlas.issues.providers.jira.api.users").get_myself,
			search_query = M.search_query,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			views = M.views,
			refresh = M.on_refresh,
		},
		comments = {
			fetch_activity = M.fetch_activity,
			fetch_conversation = M.fetch_conversation,
			add_comment = M.add_comment,
			reply_comment = M.reply_comment,
			edit_comment = M.edit_comment,
			delete_comment = M.delete_comment,
			comment_completion = function(opts)
				return require("atlas.issues.providers.jira.completion.author").build_completion(opts)
			end,
		},
		actions = require("atlas.issues.providers.jira.actions"),
		ui = {
			setup = require("atlas.issues.providers.jira.highlights").setup,
			detail = require("atlas.issues.providers.jira.ui.detail"),
		},
	},
}
