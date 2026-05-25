local icons = require("atlas.ui.shared.icons")
local main_ui = require("atlas.pulls.providers.github.ui.main")

---@class GitHubProvider : PullsProvider
local M = {
	id = "github",
	name = "GitHub",
	icon = icons.pulls_provider("github", "provider"),
	hl_group = "AtlasGitHubTheme",
	render = main_ui.render,
	panel = require("atlas.pulls.providers.github.ui.panel"),
	repo_panel = require("atlas.pulls.providers.github.ui.repo_panel"),
}

function M.setup()
	require("atlas.pulls.providers.github.highlights").setup()
end

---@return AtlasGitHubConfig
local function github_config()
	local config = require("atlas.config")
	return ((config.options.pulls or {}).providers or {}).github or {}
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local users_api = require("atlas.pulls.providers.github.api.users")
	local state = require("atlas.pulls.providers.github.state")

	users_api.fetch_user(function(user, err)
		if user then
			state.current_user = user
		end
		on_done(user, err)
	end)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local pr_api = require("atlas.pulls.providers.github.api.pullrequests")
	local pulls_state = require("atlas.pulls.state")
	---@cast view AtlasGitHubViewConfig

	local search = view.search or ""
	if search == "" then
		vim.schedule(function()
			on_done({}, { "No search query configured for view" })
		end)
		return nil
	end

	local query = search
	if not query:find("is:pr") then
		query = "is:pr " .. query
	end

	local f = pulls_state.status_filters or {}
	local open, merged, declined = f.OPEN, f.MERGED, f.DECLINED
	if open and not merged and not declined then
		query = query .. " is:open"
	elseif merged and not open and not declined then
		query = query .. " is:merged"
	elseif declined and not open and not merged then
		query = query .. " is:closed -is:merged"
	elseif merged and declined and not open then
		query = query .. " is:closed"
	end

	pulls_state.last_search_query = query

	return pr_api.search_prs(query, on_done, {
		force_load = opts.force_load == true,
		limit = opts.pagelen,
	})
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.github.api.pullrequests")
	local owner = pr.workspace or ""
	local repo = pr.repo or ""
	if owner == "" or repo == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end
	return pr_api.get_pr(owner, repo, pr.id, on_done, { force_load = opts.force_load == true })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").get_description(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").get_reviewers(pr, opts, on_done)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	return require("atlas.pulls.providers.github.api.checks").get_builds(pr, nil, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_merge_checks(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.checks").get_merge_checks_summary(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").get_diffstat(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.activity").fetch_activity(pr, opts, on_done)
end

local GITHUB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").github()

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[], reaction_options: PullsReactionOption[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	local activity_api = require("atlas.pulls.providers.github.api.activity")
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")

	---@param description string
	local function build(result, description)
		local comments = type(result.comments) == "table" and result.comments or {}
		if description ~= "" then
			local author = pr.author
			table.insert(comments, 1, {
				id = "__body__",
				parent_id = nil,
				author = author and {
					name = author.name or author.username or "",
					nickname = author.nickname or author.username or author.name or "",
					id = author.id or "",
				} or nil,
				content_raw = description,
				created_on = pr.created_on or "",
			})
		end
		on_done({
			comments = comments,
			events = type(result.events) == "table" and result.events or {},
			reaction_options = GITHUB_REACTION_OPTIONS,
		}, nil)
	end

	return activity_api.fetch_conversation(pr, opts, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end
		local description = tostring(pr.description or "")
		if description ~= "" then
			build(result, description)
			return
		end

		pullrequests.get_description(pr, opts, function(desc, _)
			build(result, tostring(desc or ""))
		end)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(pr, comment, key, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end
	local cli = require("atlas.pulls.providers.github.api.cli")
	local endpoint
	if tostring(comment.id) == "__body__" then
		endpoint = string.format("repos/%s/issues/%s/reactions", repo_slug, tostring(pr.id))
	else
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", repo_slug, tostring(comment.id))
	end
	return cli.gh({
		"api",
		"-X",
		"POST",
		endpoint,
		"-f",
		"content=" .. key,
	}, function(_, err)
		if err then
			on_done(false, err)
		else
			on_done(true, nil)
		end
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.comments").fetch_comments(pr, opts, on_done)
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	return require("atlas.pulls.providers.github.api.comments").add_comment(pr, content, opts, on_done)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	return require("atlas.pulls.providers.github.api.comments").reply_comment(pr, parent, content, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	return require("atlas.pulls.providers.github.api.comments").edit_comment(pr, comment, on_done)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	return require("atlas.pulls.providers.github.api.comments").delete_comment(pr, target, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.commits").fetch_commits(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.commits").fetch_diff(pr, opts, on_done)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	return require("atlas.pulls.providers.github.api.repositories").fetch_detail(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	return require("atlas.pulls.providers.github.api.repositories").fetch_branches(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	return require("atlas.pulls.providers.github.api.repositories").fetch_tags(repo, opts, on_done)
end

---@param pr PullRequest|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.github.actions")
	actions.open({ pr = pr, source = source }, function(result, _)
		if result == nil then
			on_done(nil)
			return
		end
		on_done({ changed_pr = result.changed_pr, message = result.message })
	end)
end

function M.search()
	local actions = require("atlas.pulls.providers.github.actions")
	actions.run("search", { source = "main" }, function() end)
end

function M.views()
	local views = github_config().views
	if type(views) == "table" and #views > 0 then
		return views
	end
	return {
		{ name = "Me", key = "1", search = "involves:@me", layout = "compact" },
	}
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.github.api.notifications")
	local merged = vim.tbl_extend("force", { all = true, per_page = 100 }, opts or {})
	return notifications.fetch(merged, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	return require("atlas.pulls.providers.github.api.notifications").mark_read(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_done(id, on_done)
	return require("atlas.pulls.providers.github.api.notifications").mark_done(id, on_done)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").create_pr(opts, on_done)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/collaborators?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local items = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				local login = type(raw) == "table" and tostring(raw.login or "") or ""
				if login ~= "" then
					table.insert(items, {
						label = "@" .. login,
						provider_id = login,
						selected = false,
						default = false,
					})
				end
			end
		end

		on_done(items, nil)
	end)
end

return M
