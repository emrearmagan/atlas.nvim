local icons = require("atlas.ui.shared.icons")

---@class GitLabPullsProvider : PullsProvider
local M = {
	id = "gitlab",
	name = "GitLab",
	icon = icons.pulls_provider("gitlab", "provider"),
	hl_group = "AtlasGitLabTheme",
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
	return mr_api.list_mrs(view, {
		force_load = opts and opts.force_load == true or false,
		pagelen = opts and opts.pagelen or 50,
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
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.mergerequests").get_description(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	return require("atlas.pulls.providers.gitlab.api.mergerequests").get_reviewers(pr, opts, on_done)
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
