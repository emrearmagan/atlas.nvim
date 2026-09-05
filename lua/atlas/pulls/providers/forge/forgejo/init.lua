---@class ForgejoPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class ForgejoPullRequestDetails : PullRequestDetails
---@field label_ids integer[]

require("atlas.pulls.providers.forge.forgejo.config")

local api = require("atlas.pulls.providers.forge.forgejo.api")
local comments_api = require("atlas.pulls.providers.forge.forgejo.api.comments")
local checks_api = api.checks
local commits_api = api.commits
local files_api = api.files
local service = require("atlas.providers.forge.forgejo.api")
local notifications_api = service.notifications
local pipelines_api = require("atlas.pulls.providers.forge.forgejo.api.pipelines")
local pullrequests_api = api.pullrequests
local repositories_api = api.repositories
local reviews_api = require("atlas.pulls.providers.forge.forgejo.api.reviews")
local git = require("atlas.core.git")
local query = require("atlas.pulls.providers.forge.query")

---@param view AtlasForgejoPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	local api_view, statuses = query.for_api(view)
	local global = vim.trim(api_view.repo or "") == ""
	local fetch = global and pullrequests_api.search_global or pullrequests_api.list
	return fetch(api_view, statuses, opts, function(page, err)
		if err then
			on_done({ items = {} }, { err })
			return
		end
		on_done(page, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	return comments_api.fetch(pr, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local ordered = {}
		local sequence = 0
		local function add(kind, created_on, entity, id)
			sequence = sequence + 1
			table.insert(ordered, {
				sequence = sequence,
				item = { id = id, kind = kind, created_on = created_on, entity = entity },
			})
		end

		for _, comment in ipairs(result.comments) do
			add("comment", comment.created_on, comment, "comment:" .. tostring(comment.id))
		end
		for index, event in ipairs(result.events) do
			local created_on = event.date
			add(
				"activity",
				created_on,
				event,
				table.concat({ "activity", created_on, event.kind, tostring(index) }, ":")
			)
		end
		table.sort(ordered, function(left, right)
			if left.item.created_on == right.item.created_on then
				return left.sequence < right.sequence
			end
			return left.item.created_on < right.item.created_on
		end)
		local items = {}
		for _, value in ipairs(ordered) do
			table.insert(items, value.item)
		end
		on_done(items, nil)
	end)
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(pr, item, key, on_done)
	if item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	return comments_api.add_reaction(pr, item.entity, key, on_done)
end

---@return AtlasForgejoPullsViewConfig[]
local function views()
	local cfg = require("atlas.config").domain_options("forgejo", "pulls") or {}
	local configured = cfg.views or {}
	if #configured == 0 then
		configured = { { name = "Pull Requests", key = "1", layout = "compact" } }
	end
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "forgejo" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].repo = repo
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasForgejoPullsViewConfig
local function view_for_target(target)
	return { name = "Search", layout = "compact", repo = target.repo_full_name }
end

local comments = {
	fetch_conversation = fetch_conversation,
	reaction_options = require("atlas.ui.shared.emojis").github(),
	comment_completion = require("atlas.providers.forge.completion.author").for_pulls,
	add_comment = comments_api.add,
	edit_comment = comments_api.edit,
	delete_comment = comments_api.delete,
	add_reaction = add_reaction,
}

local reviews = {
	fetch = reviews_api.fetch,
	fetch_review_context = reviews_api.fetch_context,
	start_review = reviews_api.start_review,
	submit_review = reviews_api.submit_review,
	approve = reviews_api.approve,
	request_changes = reviews_api.request_changes,
	discard_review = reviews_api.discard_review,
}

local repository = {
	fetch_details = repositories_api.detail,
	fetch_branches = repositories_api.branches,
	fetch_tags = repositories_api.tags,
	fetch_issues = repositories_api.fetch_issues,
	delete_branch = repositories_api.delete_branch,
}

local provider_actions =
	require("atlas.pulls.providers.forge.actions.registry").new("forgejo", pullrequests_api, repositories_api)
local pipeline_actions = require("atlas.pulls.providers.forge.forgejo.actions.pipelines")

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = query.resolve,
	capabilities = {
		core = {
			fetch_user = pullrequests_api.fetch_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.get,
			create_pr = pullrequests_api.create,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.description,
			fetch_reviewers = pullrequests_api.reviewers,
			fetch_diffstat = files_api.diffstat,
			fetch_commits = commits_api.fetch,
			fetch_merge_checks = checks_api.fetch,
		},
		comments = comments,
		reviews = reviews,
		repository = repository,
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = pipeline_actions,
		},
		notifications = notifications_api,
		actions = provider_actions,
		ui = {
			detail = require("atlas.pulls.providers.forge.ui.detail").new("forgejo"),
			repo_detail = require("atlas.pulls.providers.forge.ui.repo_detail").new("forgejo"),
		},
	},
}
