---@class GitHubIssue : Issue
---@field repo_full_name string
---@field number integer
---@field node_id string|nil
---@field is_pinned boolean

---@class GitHubIssueMilestone : IssueMilestone
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class GitHubIssueDetails : IssueDetails
---@field milestone GitHubIssueMilestone|nil
---@field sub_issues GitHubIssue[]

local actions = require("atlas.issues.providers.github.actions")
local author_completion = require("atlas.providers.github.completion.author")
local comments_api = require("atlas.issues.providers.github.api.comments")
local config = require("atlas.config")
local client = require("atlas.providers.github.client")
local emojis = require("atlas.ui.shared.emojis")
local issue_cache = require("atlas.issues.providers.github.api.cache")
local issues_api = require("atlas.issues.providers.github.api.issues")
local notifications_api = require("atlas.providers.github.notifications")
local timeline_api = require("atlas.issues.providers.github.api.timeline")
local ui_detail = require("atlas.issues.providers.github.ui.detail")
local users_api = require("atlas.issues.providers.github.api.users")
local git = require("atlas.core.git")

---@param view IssuesViewConfig
---@return string
local function resolve_search(view)
	---@cast view AtlasGitHubIssuesViewConfig
	local search = view.search or ""
	if not search:lower():find("is:issue", 1, true) then
		search = vim.trim(search .. " is:issue")
	end
	return search
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_issues(view, opts, on_done)
	local search = resolve_search(view)
	return issues_api.search_issues(search, function(page, err)
		if err then
			on_done({ items = {} }, err)
			return
		end

		local pinned, rest = {}, {}
		for _, issue in ipairs(page.items) do
			---@cast issue GitHubIssue
			if issue.is_pinned == true then
				table.insert(pinned, issue)
			else
				table.insert(rest, issue)
			end
		end
		local sorted = vim.list_extend({}, pinned)
		vim.list_extend(sorted, rest)
		page.items = sorted

		on_done(page, nil)
	end, {
		force_refresh = opts.force_refresh == true,
		pagelen = opts.pagelen,
		cursor = opts.cursor,
	})
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_issue(ref, opts, on_done)
	opts = opts or {}
	return issues_api.get_issue(ref.key, on_done, {
		force_refresh = opts.force_refresh,
	})
end

---@param issue Issue
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function update_description(issue, content, on_done)
	---@cast issue GitHubIssue
	local slug = issue.repo_full_name
	local number = issue.number
	if slug == "" then
		on_done(false, "Invalid issue")
		return nil
	end

	return client.gh({
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
		issue_cache.invalidate(issue.key)
		on_done(true, nil)
	end, {
		action = "Update issue description",
		slug = slug,
		number = number,
	})
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	return timeline_api.list_conversation(issue.key, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end

		local items = {}
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
	end, { force_refresh = opts.force_refresh == true })
end

---@param issue Issue
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(issue, item, key, on_done)
	---@cast issue GitHubIssue
	local slug = issue.repo_full_name
	if slug == "" then
		on_done(false, "Invalid issue")
		return nil
	end

	if item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	local comment = item.entity
	---@cast comment IssueComment
	local endpoint = string.format("repos/%s/issues/comments/%s/reactions", slug, tostring(comment.id))

	return client.api("POST", endpoint, { content = key }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		issue_cache.invalidate(issue.key)
		on_done(true, nil)
	end, {
		action = "Add issue reaction",
		key = issue.key,
		reaction = key,
	})
end

---@return AtlasGitHubIssuesViewConfig[]
local function views()
	local cfg = config.domain_options("github", "issues") or {}
	local configured = cfg.views
	if not configured or #configured == 0 then
		configured = {
			{
				name = "Assigned",
				key = "1",
				search = "assignee:@me is:open",
			},
		}
	end
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "github" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			local additional = (view.search and view.search ~= "") and (" " .. view.search) or ""
			resolved[i].search = string.format("repo:%s%s", repo, additional)
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
local function view_for_target(target)
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
local function issue_ref(target)
	if target.owner and target.repo and target.number then
		return { key = string.format("%s/%s#%d", target.owner, target.repo, target.number) }
	end
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = resolve_search,
	issue_ref = issue_ref,
	capabilities = {
		core = {
			fetch_user = users_api.get_user,
			fetch_issues = fetch_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = fetch_issue,
			update_description = update_description,
		},
		comments = {
			reaction_options = emojis.github(),
			comment_completion = author_completion.for_issues,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add,
			edit_comment = comments_api.edit,
			delete_comment = comments_api.delete,
			add_reaction = add_reaction,
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			detail = ui_detail,
		},
	},
}
