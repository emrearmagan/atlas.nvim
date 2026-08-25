---@class ForgejoPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class ForgejoPullRequestDetails : PullRequestDetails
---@field label_ids integer[]

require("atlas.pulls.providers.forgejo.config")

local comments_api = require("atlas.pulls.providers.forgejo.api.comments")
local commits_api = require("atlas.pulls.providers.forgejo.api.commits")
local files_api = require("atlas.pulls.providers.forgejo.api.files")
local notifications_api = require("atlas.providers.forgejo.notifications")
local pipelines_api = require("atlas.pulls.providers.forgejo.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.forgejo.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.forgejo.api.repositories")
local reviews_api = require("atlas.pulls.providers.forgejo.api.reviews")
local git = require("atlas.core.git")

---@param opts PullsFetchOpts
---@return string[]
local function active_statuses(opts)
	local configured = {}
	for _, state in ipairs(opts.states or { "open" }) do
		configured[state:upper()] = true
	end
	local statuses = {}
	for _, status in ipairs({ "OPEN", "MERGED", "DECLINED" }) do
		if configured[status] then
			table.insert(statuses, status)
		end
	end
	return #statuses > 0 and statuses or { "OPEN" }
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@return string
local function search_query(view, opts)
	---@cast view AtlasForgejoPullsSearchConfig
	local repo = vim.trim(view.repo or "")
	local query = repo == "" and { "type:pulls" } or { "repo:" .. repo }
	for _, status in ipairs(active_statuses(opts)) do
		table.insert(query, "is:" .. status:lower())
	end
	local extra_keys = vim.tbl_keys(view.extra_params or {})
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			table.insert(query, key .. ":" .. tostring(value))
		end
	end
	if vim.trim(view.search or "") ~= "" then
		table.insert(query, view.search)
	end
	return table.concat(query, " ")
end

---@param view AtlasForgejoPullsSearchConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	local statuses = active_statuses(opts)
	local global = vim.trim(view.repo or "") == ""
	local fetch = global and pullrequests_api.search_global or pullrequests_api.list
	return fetch(view, {
		statuses = statuses,
		pagelen = opts.pagelen or 50,
		force_load = opts.force_load == true,
	}, function(pulls, err)
		if err then
			on_done({}, { err })
			return
		end
		on_done(pulls or {}, nil)
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
local function search_view(target)
	return { name = "Search", layout = "compact", repo = target.repo_full_name }
end

local comments = {
	fetch_conversation = fetch_conversation,
	reaction_options = require("atlas.ui.shared.emojis").github(),
	comment_completion = require("atlas.providers.forgejo.completion.author").for_pulls,
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

return {
	views = views,
	search_view = search_view,
	capabilities = {
		core = {
			fetch_user = pullrequests_api.fetch_user,
			search_query = search_query,
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
		},
		comments = comments,
		reviews = reviews,
		repository = repository,
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = require("atlas.pulls.providers.forgejo.actions.pipelines"),
		},
		notifications = notifications_api,
		actions = require("atlas.pulls.providers.forgejo.actions"),
		ui = {
			setup = require("atlas.providers.forgejo.highlights").setup,
			detail = require("atlas.pulls.providers.forgejo.ui.detail"),
			repo_detail = require("atlas.pulls.providers.forgejo.ui.repo_detail"),
		},
	},
}
