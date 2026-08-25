---@class GitHubPullRequest : PullRequest
---@field node_id string|nil
---@field review_decision string|nil
---@field check_status string|nil
---@field lines_added number|nil
---@field lines_removed number|nil

---@class GitHubPullRequestDetails : PullRequestDetails, GitHubPullRequest
---@field reactions table<string, integer>|nil

local actions = require("atlas.pulls.providers.github.actions")
local activity_api = require("atlas.pulls.providers.github.api.activity")
local changes_api = require("atlas.pulls.providers.github.api.changes")
local checks_api = require("atlas.pulls.providers.github.api.checks")
local config = require("atlas.config")
local cli = require("atlas.providers.github.client")
local comments_api = require("atlas.pulls.providers.github.api.comments")
local notifications_api = require("atlas.providers.github.notifications")
local pipelines_api = require("atlas.pulls.providers.github.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.github.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.github.api.repositories")
local reviews_api = require("atlas.pulls.providers.github.api.reviews")
local users_api = require("atlas.pulls.providers.github.api.users")
local git = require("atlas.core.git")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_user(on_done)
	return users_api.fetch_user(function(user, err)
		if user then
			require("atlas.pulls.providers.github.state").current_user = user
		end
		on_done(user, err)
	end)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@return string
local function search_query(view, opts)
	---@cast view AtlasGitHubViewConfig
	local search = view.search or ""
	if search == "" then
		return ""
	end

	local query = search:find("is:pr") and search or "is:pr " .. search
	local filters = require("atlas.pulls.state").status_filters or {}
	local open, merged, declined = filters.OPEN, filters.MERGED, filters.DECLINED
	if opts.state == "open" or (opts.state == nil and open and not merged and not declined) then
		query = query .. " is:open"
	elseif opts.state == "merged" or (opts.state == nil and merged and not open and not declined) then
		query = query .. " is:merged"
	elseif opts.state == "declined" or (opts.state == nil and declined and not open and not merged) then
		query = query .. " is:closed -is:merged"
	elseif opts.state == nil and merged and declined and not open then
		query = query .. " is:closed"
	end

	return query
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	local query = search_query(view, opts)
	if query == "" then
		vim.schedule(function()
			on_done({}, { "No search query configured for view" })
		end)
		return nil
	end
	return pullrequests_api.search_prs(query, on_done, {
		force_load = opts.force_load == true,
		limit = opts.pagelen,
	})
end

---@param refs PullRequestRef[]
---@param _opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_by_refs(refs, _opts, on_done)
	return pullrequests_api.fetch_by_refs(refs, on_done)
end

---@param ref PullRequestRef
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequestDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequest(ref, opts, on_done)
	local owner, repo = ref.repo_full_name:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end
	return pullrequests_api.get_pr(owner, repo, ref.id, on_done, { force_load = opts.force_load == true })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	return activity_api.fetch_conversation(pr, opts, on_done)
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(pr, item, key, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end

	local endpoint
	if item.kind == "description" then
		endpoint = string.format("repos/%s/issues/%s/reactions", repo_slug, tostring(pr.id))
	elseif item.kind == "comment" then
		---@type PullsComment
		local comment = item.entity
		if comment.inline or comment.file then
			endpoint = string.format("repos/%s/pulls/comments/%s/reactions", repo_slug, tostring(comment.id))
		else
			endpoint = string.format("repos/%s/issues/comments/%s/reactions", repo_slug, tostring(comment.id))
		end
	else
		on_done(false, "This item does not support reactions")
		return nil
	end
	return cli.gh({ "api", "-X", "POST", endpoint, "-f", "content=" .. key }, function(_, err)
		on_done(err == nil, err)
	end, {
		action = "Add PR reaction",
		repo = repo_slug,
		number = pr.id,
		reaction = key,
	})
end

---@param view AtlasGitHubViewConfig
---@return AtlasGitHubViewConfig
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

---@return AtlasGitHubViewConfig[]
local function views()
	local options = config.domain_options("github", "pulls") or {}
	---@cast options AtlasGitHubPullsConfig
	local configured = type(options.views) == "table" and #options.views > 0 and options.views
		or { { name = "Me", key = "1", search = "involves:@me", layout = "compact" } }
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = resolve_cur_repo(view)
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function search_view(target)
	local search = string.format("repo:%s/%s is:pr", target.owner, target.repo)
	if target.number then
		search = search .. " " .. tostring(target.number)
	end
	return {
		name = "Search",
		layout = "compact",
		search = search,
	}
end

return {
	search_view = search_view,
	capabilities = {
		core = {
			fetch_user = fetch_user,
			search_query = search_query,
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = fetch_by_refs,
			fetch_pullrequest = fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_reviewers = pullrequests_api.get_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.get_description,
			fetch_merge_checks = checks_api.fetch,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_activity = activity_api.fetch_activity,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
			views = views,
		},
		comments = {
			reaction_options = require("atlas.ui.shared.emojis").github(),
			comment_completion = require("atlas.providers.github.completion.author").for_pulls,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_review_context = reviews_api.fetch_context,
			edit_review = reviews_api.edit_review,
			start_review = reviews_api.start,
			submit_review = reviews_api.submit,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard,
			set_file_reviewed = reviews_api.set_file_reviewed,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			fetch_issues = repositories_api.fetch_issues,
		},
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = require("atlas.pulls.providers.github.actions.pipelines"),
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.github.highlights").setup,
			detail = require("atlas.pulls.providers.github.ui.detail"),
			repo_detail = require("atlas.pulls.providers.github.ui.repo_detail"),
		},
	},
}
