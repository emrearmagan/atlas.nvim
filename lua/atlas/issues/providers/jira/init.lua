local icons = require("atlas.ui.shared.icons")
local config = require("atlas.issues.providers.jira.api.config")

---@class JiraProvider : IssuesProvider
local M = {
	id = "jira",
	name = "Jira",
	icon = icons.issues_provider("jira", "provider"),
	hl_group = "AtlasJiraTheme",
	panel = require("atlas.issues.providers.jira.ui.panel"),
}

function M.setup()
	require("atlas.issues.providers.jira.highlights").setup()
end

function M.on_refresh()
	local service = require("atlas.issues.providers.jira.api.service")
	service.clear_memory_cache()
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	return require("atlas.issues.providers.jira.ui.renderer").format_row(issue, is_child)
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	return require("atlas.issues.providers.jira.ui.renderer").cell_hl(row, col, ctx)
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local users_api = require("atlas.issues.providers.jira.api.users")
	users_api.get_myself(on_done)
end

---@param config AtlasIssuesConfig
---@param opts IssuesFetchOpts|nil
---@return boolean
local function relationships_enabled(config, opts)
	if opts and (opts.with_relationships == false or opts.layout == "compact") then
		return false
	end
	return config.with_relationships ~= false
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
		if type(issue) == "table" and type(issue.key) == "string" and issue.key ~= "" then
			existing[issue.key] = true
		end
	end

	local missing = {}
	local seen = {}
	for _, issue in ipairs(issues or {}) do
		if type(issue) == "table" and type(issue.parent) == "table" then
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

	local jql = tostring(view and view.jql or "")
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
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(issue_key, opts, on_done)
	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.get_issue(issue_key, on_done)
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(issue, opts, on_done)
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
	return comments_api.add_comment(issue_key, content, on_done)
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

	return M.fetch_comments(issue, { force_load = force }, function(comments, err)
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

---@param action_id string
---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.run_action(action_id, ctx, on_done)
	local jira_actions = require("atlas.issues.providers.jira.actions")
	jira_actions.run(action_id, ctx, on_done)
end

---@param issue Issue|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil, err: string|nil)
function M.open_actions(issue, source, on_done)
	local jira_actions = require("atlas.issues.providers.jira.actions")
	jira_actions.open({ issue = issue, source = source }, on_done)
end

---@param on_done fun(result: table|nil, err: string|nil)|nil
function M.search(on_done)
	local jira_actions = require("atlas.issues.providers.jira.actions")
	jira_actions.run("search_issues", { issue = nil, source = "main" }, function(result, err)
		if on_done ~= nil then
			on_done(result, err)
		end
	end)
end

---@param issue Issue
---@param on_done fun(is_subscribed: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.toggle_subscription(issue, on_done)
	local issue_key = tostring(issue.key or "")
	if issue_key == "" then
		vim.schedule(function()
			on_done(nil, "Missing issue key")
		end)
		return nil
	end

	local service = require("atlas.issues.providers.jira.api.service")
	if issue.is_subscribed ~= true then
		return service.request("POST", "/issue/" .. issue_key .. "/watchers", nil, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			issue.is_subscribed = true
			on_done(true, nil)
		end)
	end

	local function unsubscribe(account_id)
		local jira_config = config.jira_config()
		local user_param = "accountId=" .. account_id
		if jira_config.api_type == "server" then
			user_param = "username=" .. account_id
		end
		return service.request(
			"DELETE",
			string.format("/issue/%s/watchers?%s", issue_key, user_param),
			nil,
			function(_, err)
				if err then
					on_done(nil, err)
					return
				end
				issue.is_subscribed = false
				on_done(false, nil)
			end
		)
	end

	local issues_state = require("atlas.issues.state")
	local current = issues_state.current_user
	if current and tostring(current.account_id or "") ~= "" then
		return unsubscribe(current.account_id)
	end

	local users_api = require("atlas.issues.providers.jira.api.users")
	return users_api.get_myself(function(user, err)
		if err or not user or user.account_id == "" then
			on_done(nil, err or "Failed to fetch Jira user")
			return
		end
		unsubscribe(user.account_id)
	end)
end

---@return AtlasJiraViewConfig[]
function M.views()
	local cfg = require("atlas.issues.providers.jira.api.config").jira_config()
	if cfg.views ~= nil then
		return cfg.views
	end
	return {
		{
			name = "Issues",
			key = "1",
			jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
		},
	}
end

return M
