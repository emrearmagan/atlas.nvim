local icons = require("atlas.ui.shared.icons")

---@class GitLabPullsProvider : PullsProvider
local M = {
	id = "gitlab",
	name = "GitLab",
	icon = icons.pulls_provider("gitlab", "provider"),
	hl_group = "AtlasGitLabTheme",
	panel = require("atlas.pulls.providers.gitlab.ui.panel"),
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
