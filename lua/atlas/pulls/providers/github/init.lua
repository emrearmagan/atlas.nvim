---@class GitHubPullRequest : PullRequest
---@field node_id string|nil
---@field review_decision string|nil
---@field check_status string|nil
---@field lines_added number
---@field lines_removed number

---@class GitHubPullRequestDetails : PullRequestDetails
---@field assignees PullsAuthor[]
---@field labels PullsLabel[]

local actions = require("atlas.pulls.providers.github.actions")
local activity_api = require("atlas.pulls.providers.github.api.activity")
local author_completion = require("atlas.providers.github.completion.author")
local changes_api = require("atlas.pulls.providers.github.api.changes")
local checks_api = require("atlas.pulls.providers.github.api.checks")
local config = require("atlas.config")
local cli = require("atlas.providers.github.client")
local comments_api = require("atlas.pulls.providers.github.api.comments")
local emojis = require("atlas.ui.shared.emojis")
local highlights = require("atlas.pulls.providers.github.highlights")
local notifications_api = require("atlas.providers.github.notifications")
local pipeline_actions = require("atlas.pulls.providers.github.actions.pipelines")
local pipelines_api = require("atlas.pulls.providers.github.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.github.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.github.api.repositories")
local reviews_api = require("atlas.pulls.providers.github.api.reviews")
local search_query = require("atlas.providers.github.query")
local ui_detail = require("atlas.pulls.providers.github.ui.detail")
local ui_repo_detail = require("atlas.pulls.providers.github.ui.repo_detail")
local users_api = require("atlas.pulls.providers.github.api.users")
local git = require("atlas.core.git")

---@param ref PullRequestRef
---@param opts PullsFetchOpts
---@param on_done fun(details: PullRequestDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequest(ref, opts, on_done)
	local owner, repo = ref.repo_full_name:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end
	return pullrequests_api.get_pr(owner, repo, ref.id, on_done, { force_refresh = opts.force_refresh == true })
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(pr, item, key, on_done)
	local repo_slug = pr.repo_full_name
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end

	if item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	---@type PullsComment
	local comment = item.entity
	local endpoint
	if comment.inline or comment.file then
		endpoint = string.format("repos/%s/pulls/comments/%s/reactions", repo_slug, tostring(comment.id))
	else
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", repo_slug, tostring(comment.id))
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

---@return AtlasGitHubViewConfig[]
local function views()
	local options = config.domain_options("github", "pulls") or {}
	---@cast options AtlasGitHubPullsConfig
	local configured = options.views
	if not configured or #configured == 0 then
		configured = { { name = "Me", key = "1", search = "involves:@me", layout = "compact" } }
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
---@return AtlasPullsViewConfig
local function view_for_target(target)
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
	views = views,
	view_for_target = view_for_target,
	resolve_search = search_query.query,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			fetch_pullrequests = function(view, opts, on_done)
				return pullrequests_api.fetch_search(search_query.queries(view), opts, on_done)
			end,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_reviewers = reviews_api.fetch_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.get_description,
			fetch_merge_checks = checks_api.fetch,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
		},
		comments = {
			reaction_options = emojis.github(),
			comment_completion = author_completion.for_pulls,
			fetch_conversation = activity_api.fetch_conversation,
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
			actions = pipeline_actions,
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			setup = highlights.setup,
			detail = ui_detail,
			repo_detail = ui_repo_detail,
		},
	},
}
