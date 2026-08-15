---@class JiraProvider : IssuesProvider
local M = {}

local resolver = require("atlas.providers.resolve")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve_target(value, parsed)
	local reference = value:upper():match("^([A-Z][A-Z0-9_]*%-%d+)$")
	if reference then
		local base_url = resolver.base_url({ provider = "jira", domain = "issues", host = "" })
		return {
			provider = "jira",
			domain = "issues",
			entity = "issue",
			host = base_url:match("^https?://([^/]+)") or "",
			issue_key = reference,
			url = base_url .. "/browse/" .. reference,
		}
	end

	if parsed == nil then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("issues", "jira"))
	if path == nil then
		return nil, nil
	end

	local issue_key, tail = path:match("^/browse/([A-Z][A-Z0-9_]*%-%d+)(.*)$")
	if issue_key == nil or not resolver.valid_tail(tail) then
		return nil, "Unsupported Jira URL. Expected a /browse/KEY issue URL"
	end

	return {
		provider = "jira",
		domain = "issues",
		entity = "issue",
		url = value,
		host = parsed.host,
		issue_key = issue_key,
	}
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
local function search_view(target)
	return { name = "Search", layout = "compact", jql = "key = " .. target.issue_key }
end

---@param target AtlasTarget
---@return string|nil
local function target_issue_key(target)
	return target.issue_key
end

function M.on_refresh()
	local service = require("atlas.issues.providers.jira.api.service")
	service.clear_memory_cache()
end

---@param issues_config AtlasIssuesConfig
---@param opts IssuesFetchOpts|nil
---@return boolean
local function relationships_enabled(issues_config, opts)
	if opts and (opts.with_relationships == false or opts.layout == "compact") then
		return false
	end
	return issues_config.with_relationships ~= false
end

---@param issues Issue[]
---@param opts IssuesFetchOpts
---@param on_done fun(enriched: Issue[])
local function enrich_with_parents(issues, opts, on_done)
	local issues_cfg = require("atlas.config").options.issues or {}
	if not relationships_enabled(issues_cfg, opts) then
		on_done(issues)
		return
	end

	local existing = {}
	for _, issue in ipairs(issues or {}) do
		if issue.key ~= "" then
			existing[issue.key] = true
		end
	end

	local missing = {}
	local seen = {}
	for _, issue in ipairs(issues or {}) do
		if issue.parent then
			local pk = tostring(issue.parent.key or "")
			if pk ~= "" and not existing[pk] and not seen[pk] then
				seen[pk] = true
				table.insert(missing, pk)
			end
		end
	end

	if #missing == 0 then
		on_done(issues)
		return
	end

	local escaped = {}
	for _, key in ipairs(missing) do
		table.insert(escaped, string.format('"%s"', key:gsub('"', '\\"')))
	end
	local parent_jql = "key in (" .. table.concat(escaped, ",") .. ")"

	local issues_api = require("atlas.issues.providers.jira.api.issues")
	issues_api.search_issues(parent_jql, function(page, err)
		if err or page == nil then
			on_done(issues)
			return
		end
		for _, parent in ipairs(page.issues or {}) do
			local pk = tostring(parent.key or "")
			if pk ~= "" and not existing[pk] then
				existing[pk] = true
				table.insert(issues, parent)
			end
		end
		on_done(issues)
	end, {
		force_load = opts and opts.force_load == true or false,
		max_results = #missing,
	})
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	---@cast view AtlasJiraViewConfig

	local jql = tostring(view and (view.jql or view.search) or "")
	if jql == "" then
		on_done({}, nil, true, "Missing Jira view JQL")
		return nil
	end

	return issues_api.search_issues(jql, function(page, err)
		if err or page == nil then
			on_done({}, nil, true, err or "Failed to fetch issues")
			return
		end

		enrich_with_parents(page.issues or {}, opts or {}, function(enriched)
			on_done(enriched, page.nextPageToken, page.isLast == true, nil)
		end)
	end, {
		force_load = opts and opts.force_load == true or false,
		next_page_token = opts and opts.next_page_token or nil,
		max_results = opts and opts.max_results or nil,
	})
end

---@param issue_key string
---@param _opts IssuesFetchOpts|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(issue_key, _opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.get_issue(issue_key, on_done)
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
---@param comment_id string
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment_id, content, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.edit_comment(issue_key, comment_id, content, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[], reaction_options: IssueReactionOption[]|nil }|nil, err: string|nil)
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
		on_done({
			comments = comments or {},
			events = {},
			reaction_options = nil,
		}, nil)
	end)
end

---@param issue Issue
---@param comment_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment_id, on_done)
	local issue_key = tostring(issue.key or "")
	local comments_api = require("atlas.issues.providers.jira.api.comments")
	return comments_api.delete_comment(issue_key, comment_id, on_done)
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
	local views = cfg.views
		or {
			{
				name = "Issues",
				key = "1",
				jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
			},
		}
	return require("atlas.ui.shared.bookmarks_view").append_to_views(views, cfg.bookmarks, "J", "JQL")
end

local renderer = require("atlas.issues.providers.jira.ui.renderer")

return {
	resolve = resolve_target,
	search_view = search_view,
	issue_key = target_issue_key,
	capabilities = {
		core = {
			fetch_user = require("atlas.issues.providers.jira.api.users").get_myself,
			fetch_issues = M.fetch_issues,
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
			comment_completion = function()
				return require("atlas.issues.providers.jira.completion.author").build_completion()
			end,
		},
		actions = require("atlas.issues.providers.jira.actions"),
		ui = {
			setup = require("atlas.issues.providers.jira.highlights").setup,
			format_row = renderer.format_row,
			cell_hl = renderer.cell_hl,
			issue_popup_content = renderer.issue_popup_content,
			panel = require("atlas.issues.providers.jira.ui.panel"),
		},
	},
}
