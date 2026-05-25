local icons = require("atlas.ui.shared.icons")

---@class GitLabPullsProvider : PullsProvider
local M = {
	id = "gitlab",
	name = "GitLab",
	icon = icons.pulls_provider("gitlab", "provider"),
	hl_group = "AtlasGitLabTheme",
	panel = require("atlas.pulls.providers.gitlab.ui.panel"),
	repo_panel = require("atlas.pulls.providers.gitlab.ui.repo_panel"),
	render = require("atlas.pulls.providers.gitlab.ui.main").render,
}

function M.setup()
	require("atlas.pulls.providers.gitlab.highlights").setup()
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	require("atlas.pulls.providers.gitlab.api.users").fetch_user(on_done)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasGitLabPullsViewConfig
	local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")
	local pulls_state = require("atlas.pulls.state")

	local f = pulls_state.status_filters or {}
	local api_state = "opened"
	if f.MERGED then
		api_state = "merged"
	elseif f.DECLINED then
		api_state = "closed"
	end

	local parts = { string.format("is:%s", api_state) }
	if view.project then
		table.insert(parts, string.format("project:%s", tostring(view.project)))
	end
	if view.group then
		table.insert(parts, string.format("group:%s", tostring(view.group)))
	end
	if view.scope then
		table.insert(parts, string.format("scope:%s", tostring(view.scope)))
	end
	if view.labels then
		table.insert(parts, string.format("labels:%s", tostring(view.labels)))
	end
	if view.milestone then
		table.insert(parts, string.format("milestone:%s", tostring(view.milestone)))
	end
	if view.author_username then
		table.insert(parts, string.format("author:%s", tostring(view.author_username)))
	end
	if view.assignee_username then
		table.insert(parts, string.format("assignee:%s", tostring(view.assignee_username)))
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end
	pulls_state.last_search_query = table.concat(parts, " ")

	return mr_api.list_mrs(view, {
		force_load = opts and opts.force_load == true or false,
		pagelen = opts and opts.pagelen or 50,
		state = api_state,
	}, function(groups, err)
		if err then
			on_done({}, { err })
			return
		end
		on_done(groups or {}, nil)
	end)
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.mergerequests").get_mr(pr, {
		force_load = opts and opts.force_load == true or false,
	}, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.mergerequests").get_description(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.mergerequests").get_reviewers(pr, opts, on_done)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	return require("atlas.pulls.providers.gitlab.api.checks").get_builds(pr, nil, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.activity").fetch_activity(pr, opts, on_done)
end

local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[], reaction_options: PullsReactionOption[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	local activity_api = require("atlas.pulls.providers.gitlab.api.activity")
	local comments_api = require("atlas.pulls.providers.gitlab.api.comments")

	local pending = 2
	local events_result, comments_result
	local first_err
	local handles = {}
	local cancelled = false

	local function finish()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if events_result == nil and comments_result == nil then
			on_done(nil, first_err or "Failed to fetch conversation")
			return
		end
		on_done({
			comments = comments_result or {},
			events = events_result or {},
			reaction_options = GITLAB_REACTION_OPTIONS,
		}, nil)
	end

	local function track(h)
		if h then
			table.insert(handles, h)
		end
	end

	track(activity_api.fetch_activity(pr, opts, function(entries, err)
		if err then
			first_err = first_err or err
		else
			events_result = entries or {}
		end
		finish()
	end))

	track(comments_api.fetch_general_comments(pr, opts, function(comments, err)
		if err then
			first_err = first_err or err
		else
			comments_result = comments or {}
		end
		finish()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					h.cancel()
				end
			end
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").fetch_comments(pr, opts, on_done)
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").add_comment(pr, content, opts, on_done)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").reply_comment(pr, parent, content, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").edit_comment(pr, comment, on_done)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").delete_comment(pr, target, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(pr, comment, key, on_done)
	return require("atlas.pulls.providers.gitlab.api.comments").add_reaction(pr, comment, key, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.commits").fetch_commits(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.files").fetch_diff(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_merge_checks(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.checks").get_merge_checks(pr, opts, on_done)
end

---@param pr PullRequest|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.gitlab.actions")
	actions.open({ pr = pr, source = source }, function(result, _)
		if result == nil then
			on_done(nil)
			return
		end
		on_done({ changed_pr = result.changed_pr, message = result.message })
	end)
end

function M.search()
	local actions = require("atlas.pulls.providers.gitlab.actions")
	actions.run("search", { source = "main" }, function() end)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.repositories").fetch_detail(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.repositories").fetch_branches(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.repositories").fetch_tags(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_repo_branch(repo, branch, on_done)
	return require("atlas.pulls.providers.gitlab.api.repositories").delete_branch(repo, branch, on_done)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local service = require("atlas.pulls.providers.gitlab.api.service")
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing project slug")
		end)
		return nil
	end
	local endpoint = string.format("/projects/%s/members/all?per_page=100", service.url_encode(slug))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			local login = type(raw) == "table" and tostring(raw.username or "") or ""
			if login ~= "" then
				table.insert(items, {
					label = "@" .. login,
					provider_id = login,
					selected = false,
					default = false,
				})
			end
		end
		on_done(items, nil)
	end)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")
	return mr_api.create_mr({
		project_path = opts.repo_slug,
		source_branch = opts.head,
		target_branch = opts.base,
		title = opts.title,
		description = opts.body,
		draft = opts.draft == true,
	}, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		on_done({
			id = result.iid,
			url = result.url,
			message = "Merge request created",
		}, nil)
	end)
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.gitlab.api.notifications")
	local merged = vim.tbl_extend("force", { state = "pending", per_page = 100 }, opts or {})
	return notifications.fetch(merged, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	return require("atlas.pulls.providers.gitlab.api.notifications").mark_read(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_done(id, on_done)
	return require("atlas.pulls.providers.gitlab.api.notifications").mark_done(id, on_done)
end

---@return AtlasGitLabPullsViewConfig[]
function M.views()
	local cfg = require("atlas.pulls.providers.gitlab.api.service").gitlab_config()
	if cfg.views ~= nil then
		return cfg.views
	end
	return {
		{
			name = "Assigned",
			key = "1",
			scope = "assigned_to_me",
			state = "opened",
		},
		{
			name = "Created",
			key = "2",
			scope = "created_by_me",
			state = "opened",
		},
	}
end

return M
