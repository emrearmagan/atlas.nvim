local icons = require("atlas.ui.shared.icons")
local config = require("atlas.config")

---@class BitbucketProvider : PullsProvider
local M = {
	id = "bitbucket",
	name = "Bitbucket",
	icon = icons.pulls_provider("bitbucket", "provider"),
	hl_group = "AtlasBitbucketTheme",
	panel = require("atlas.pulls.providers.bitbucket.ui.panel"),
}

function M.setup()
	require("atlas.pulls.providers.bitbucket.highlights").setup()
end

---@return AtlasBitbucketConfig|nil
local function bb_config()
	return config.options
			and config.options.pulls
			and config.options.pulls.providers
			and config.options.pulls.providers.bitbucket
		or nil
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local users_api = require("atlas.pulls.providers.bitbucket.api.users")
	users_api.fetch_current_user(on_done)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	---@cast view AtlasBitbucketViewConfig
	local pullrequest_state = require("atlas.pulls.state")
	local active_statuses = {}

	for status, enabled in pairs(pullrequest_state.status_filters or {}) do
		if enabled then
			table.insert(active_statuses, status)
		end
	end
	if #active_statuses == 0 then
		active_statuses = { "OPEN" }
	end

	return pr_api.fetch_pullrequests(view.repos or {}, {
		force_load = opts.force_load == true,
		pagelen = opts.pagelen,
		statuses = active_statuses,
	}, function(groups, err)
		if type(view.filter) ~= "function" then
			on_done(groups, err)
			return
		end

		local ctx = {
			user = require("atlas.pulls.state").current_user,
		}
		local filtered = {}
		for _, group in ipairs(groups or {}) do
			local prs = {}
			for _, pr in ipairs(group.prs or {}) do
				local ok, keep = pcall(view.filter, pr, ctx)
				if ok and keep ~= false then
					table.insert(prs, pr)
				end
			end
			if #prs > 0 then
				table.insert(filtered, vim.tbl_extend("force", group, { prs = prs }))
			end
		end

		on_done(filtered, err)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return nil
function M.fetch_description(pr, opts, on_done)
	vim.schedule(function()
		on_done(tostring(pr.description or ""), nil)
	end)
	return nil
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	local workspace = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")

	if workspace == "" or repo == "" then
		on_done(nil, "PR missing workspace/repo info")
		return nil
	end

	return pr_api.fetch_pullrequest(workspace, repo, pr.id, {
		force_load = opts.force_load == true,
	}, on_done)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	return repositories_api.fetch_detail(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	local raw = type(repo._raw) == "table" and repo._raw or {}
	local links = type(raw.links) == "table" and raw.links or {}
	local branches = type(links.branches) == "table" and links.branches or {}
	local branches_url = tostring(branches.href or "")
	return repositories_api.fetch_branches(branches_url, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	local raw = type(repo._raw) == "table" and repo._raw or {}
	local links = type(raw.links) == "table" and raw.links or {}
	local tags = type(links.tags) == "table" and links.tags or {}
	local tags_url = tostring(tags.href or "")
	return repositories_api.fetch_tags(tags_url, opts, on_done)
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_repo_branch(repo, branch, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	return repositories_api.delete_branch(repo, branch, on_done)
end

---@return AtlasBitbucketViewConfig[]
function M.views()
	local cfg = bb_config()
	local view_configs = cfg and cfg.views or {}
	---@type AtlasBitbucketViewConfig[]
	local out = {}

	for _, v in ipairs(view_configs) do
		table.insert(out, {
			name = v.name,
			key = v.key,

			layout = v.layout,
			repos = v.repos,
			filter = v.filter,
		})
	end

	if #out == 0 then
		table.insert(out, {
			name = "Pull Requests",
			key = "1",
			layout = "compact",
			repos = {},
		})
	end

	return out
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_reviewers(pr, opts, on_done)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_builds(pr, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_activity(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_diffstat(pr, opts, on_done)
end

---@param pr PullRequest
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.bitbucket.actions")
	local ctx = {
		pr = pr,
		source = source,
	}

	actions.open(ctx, function(result, _)
		if result == nil then
			on_done(nil)
			return
		end
		on_done({ changed_pr = result.changed_pr, message = result.message })
	end)
end

function M.search()
	local actions = require("atlas.pulls.providers.bitbucket.actions")
	actions.run("search", { source = "main" }, function() end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_commits(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: PullsDiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_diff(pr, opts, on_done)
end

---@param pr PullRequest
---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(pr, commit, opts, on_done)
	local statuses_url = tostring(commit.statuses_url or "")
	if statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_commit_status(statuses_url, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	return comments_api.fetch_comments(pr, opts, on_done)
end

---@param pr PullRequest
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	return comments_api.add_comment(pr, content, on_done)
end

---@param pr PullRequest
---@param parent_id number
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent_id, content, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	return comments_api.reply_comment(pr, parent_id, content, on_done)
end

---@param pr PullRequest
---@param comment_id number
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment_id, content, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	return comments_api.edit_comment(pr, comment_id, content, on_done)
end

---@param pr PullRequest
---@param comment_id number
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment_id, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	return comments_api.delete_comment(pr, comment_id, on_done)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.create_pr(opts, on_done)
end

return M
