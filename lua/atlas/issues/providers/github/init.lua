local M = {}

local config = require("atlas.config")
local issue_cache = require("atlas.issues.providers.github.api.cache")
local notifications_api = require("atlas.providers.github.notifications")
local git = require("atlas.core.git")

---@param view IssuesViewConfig
---@return string
function M.search_query(view)
	---@cast view AtlasGitHubIssuesViewConfig
	local search = tostring(view.search or "")
	if search ~= "" and not search:lower():find("is:issue", 1, true) then
		search = search .. " is:issue"
	end
	return search
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	local search = M.search_query(view)
	if search == "" then
		on_done({}, nil, true, "Missing search query for GitHub view")
		return nil
	end

	local issues_api = require("atlas.issues.providers.github.api.issues")
	local limit = opts and opts.max_results or 50
	local layout = tostring((view and view.layout) or (opts and opts.layout) or "plain")
	return issues_api.search_issues(search, function(issues, err)
		if err then
			on_done({}, nil, true, err)
			return
		end

		local pinned, rest = {}, {}
		for _, issue in ipairs(issues or {}) do
			if issue.is_pinned == true then
				table.insert(pinned, issue)
			else
				table.insert(rest, issue)
			end
		end
		local sorted = vim.list_extend({}, pinned)
		vim.list_extend(sorted, rest)

		on_done(sorted, nil, true, nil)
	end, {
		force_load = opts and opts.force_load == true or false,
		limit = limit,
		with_relationships = layout ~= "compact",
	})
end

---@param refs IssueRef[]
---@param _opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, _opts, on_done)
	return require("atlas.issues.providers.github.api.issues").fetch_by_refs(refs, on_done)
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	opts = opts or {}
	local api_opts = {}
	for k, v in pairs(opts) do
		api_opts[k] = v
	end
	if api_opts.layout == "compact" then
		api_opts.with_relationships = false
	end
	return require("atlas.issues.providers.github.api.issues").get_issue(ref.key, on_done, api_opts)
end

---@param issue IssueDetails
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done)
	local raw = issue._raw or {}
	local slug = tostring(raw.slug or "")
	local number = tonumber(raw.number)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue")
		return nil
	end

	local cli = require("atlas.providers.github.client")
	return cli.gh({
		"issue",
		"edit",
		tostring(number),
		"--repo",
		slug,
		"--body",
		content,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		issue_cache.invalidate(tostring(issue.key or ""))
		issue.description = content
		on_done(true, nil)
	end, {
		action = "Update issue description",
		slug = slug,
		number = number,
	})
end

---@param issue Issue
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").add(key, content, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").edit(key, tostring(comment.id), content, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local key = tostring(issue.key or "")
	return require("atlas.issues.providers.github.api.comments").delete(key, tostring(comment.id), on_done)
end

---@param issue IssueDetails
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local key = tostring(issue and issue.key or "")
	if key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local timeline = require("atlas.issues.providers.github.api.timeline")
	return timeline.list_conversation(key, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end

		local items = {}
		if issue.description ~= "" then
			table.insert(items, {
				id = "description:" .. tostring(issue.key),
				kind = "description",
				created_at = issue.created_at or "",
				entity = issue,
			})
		end
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
	end, { force_load = opts.force_refresh == true })
end

---@param issue Issue
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, item, key, on_done)
	local raw = issue._raw or {}
	local slug = tostring(raw.slug or "")
	local number = tonumber(raw.number)
	if slug == "" then
		on_done(false, "Invalid issue")
		return nil
	end

	local endpoint
	if item.kind == "description" then
		if number == nil then
			on_done(false, "Invalid issue")
			return nil
		end
		endpoint = string.format("repos/%s/issues/%d/reactions", slug, number)
	elseif item.kind == "comment" then
		local comment = item.entity
		---@cast comment IssueComment
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", slug, tostring(comment.id))
	else
		on_done(false, "This item does not support reactions")
		return nil
	end

	local cli = require("atlas.providers.github.client")
	return cli.api("POST", endpoint, { content = key }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		issue_cache.invalidate(tostring(issue.key or ""))
		on_done(true, nil)
	end, {
		action = "Add issue reaction",
		key = issue.key,
		reaction = key,
	})
end

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(issue, opts, on_done)
	local timeline = require("atlas.issues.providers.github.api.timeline")
	return timeline.list_conversation(tostring(issue.key or ""), function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		on_done(result.events, nil)
	end, { force_load = opts and opts.force_load == true or false })
end

---@param view AtlasGitHubIssuesViewConfig
---@return AtlasGitHubIssuesViewConfig
local function resolve_cur_repo(view)
	if not view.current_repo then
		return view
	end
	local root = git.repo_root()
	local info = git.local_repository(root)
	if not info or info.provider ~= "github" then
		return view
	end
	local resolved = vim.tbl_extend("force", {}, view)
	local additional = (view.search and view.search ~= "") and (" " .. view.search) or ""
	resolved.search = string.format("repo:%s%s", info.repo_full_name, additional)
	return resolved
end

---@return AtlasGitHubIssuesViewConfig[]
function M.views()
	local cfg = config.domain_options("github", "issues") or {}
	local views = type(cfg.views) == "table" and #cfg.views > 0 and cfg.views
		or {
			{
				name = "Assigned",
				key = "1",
				search = "assignee:@me is:open",
			},
		}
	local resolved = {}
	for i, view in ipairs(views) do
		resolved[i] = resolve_cur_repo(view)
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
function M.search_view(target)
	return {
		name = "Search",
		layout = "compact",
		search = string.format(
			"repo:%s/%s %s is:issue",
			target.owner,
			target.repo,
			target.number and tostring(target.number) or ""
		),
	}
end

---@param target AtlasTarget
---@return IssueRef|nil
function M.issue_ref(target)
	if target.owner and target.repo and target.number then
		return { key = string.format("%s/%s#%d", target.owner, target.repo, target.number) }
	end
end

return {
	search_view = M.search_view,
	issue_ref = M.issue_ref,
	capabilities = {
		core = {
			fetch_user = require("atlas.issues.providers.github.api.users").get_user,
			search_query = M.search_query,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			update_description = M.update_description,
			views = M.views,
		},
		comments = {
			reaction_options = require("atlas.ui.shared.emojis").github(),
			fetch_activity = M.fetch_activity,
			fetch_conversation = M.fetch_conversation,
			add_comment = M.add_comment,
			edit_comment = M.edit_comment,
			delete_comment = M.delete_comment,
			add_reaction = M.add_reaction,
		},
		notifications = notifications_api,
		actions = require("atlas.issues.providers.github.actions"),
		ui = {
			setup = require("atlas.issues.providers.github.highlights").setup,
			detail = require("atlas.issues.providers.github.ui.detail"),
		},
	},
}
