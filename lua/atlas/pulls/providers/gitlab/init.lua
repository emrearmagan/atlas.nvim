---@class GitLabPullRequestDiffRefs
---@field base_sha string|nil
---@field head_sha string|nil
---@field start_sha string|nil

---@class GitLabPullRequest : PullRequest
---@field merge_status string|nil
---@field detailed_merge_status string|nil
---@field diff_refs GitLabPullRequestDiffRefs|nil

---@class GitLabPullsLabel : PullsLabel
---@field text_color string|nil

---@class GitLabPullRequestDetails : PullRequestDetails
---@field assignees PullsAuthor[]
---@field labels GitLabPullsLabel[]

---@class GitLabPullsActivityEntry : PullsActivityEntry
---@field inline_thread boolean|nil

local actions = require("atlas.pulls.providers.gitlab.actions")
local activity_api = require("atlas.pulls.providers.gitlab.api.activity")
local author_completion = require("atlas.providers.gitlab.completion.author")
local changes_api = require("atlas.pulls.providers.gitlab.api.changes")
local checks_api = require("atlas.pulls.providers.gitlab.api.checks")
local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.gitlab.ui.detail")
local highlights = require("atlas.pulls.providers.gitlab.highlights")
local notifications_api = require("atlas.providers.gitlab.notifications")
local pipeline_actions = require("atlas.pulls.providers.gitlab.actions.pipelines")
local pipelines_api = require("atlas.pulls.providers.gitlab.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.gitlab.api.repositories")
local reviews_api = require("atlas.pulls.providers.gitlab.api.reviews")
local repo_detail_ui = require("atlas.pulls.providers.gitlab.ui.repo_detail")
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()

local API_STATES = { open = "opened", merged = "merged", declined = "closed" }

---@param opts PullsFetchOpts
---@return PullsStateFilter[]
local function selected_states(opts)
	local configured = {}
	for _, state in ipairs(opts.states or { "open" }) do
		configured[state] = true
	end
	local selected = {}
	for _, state in ipairs({ "open", "merged", "declined" }) do
		if configured[state] then
			table.insert(selected, state)
		end
	end
	return #selected > 0 and selected or { "open" }
end

---@param batches table<integer, PullRequest[]>
---@param limit integer
---@return PullRequest[]
local function merge_results(batches, limit)
	local pulls, seen = {}, {}
	for _, batch in pairs(batches) do
		for _, pr in ipairs(batch) do
			local key = pr.repo_full_name .. ":" .. tostring(pr.id)
			if not seen[key] then
				seen[key] = true
				table.insert(pulls, pr)
			end
		end
	end
	table.sort(pulls, function(left, right)
		if left.updated_on == right.updated_on then
			return left.repo_full_name .. ":" .. tostring(left.id) < right.repo_full_name .. ":" .. tostring(right.id)
		end
		return left.updated_on > right.updated_on
	end)
	while #pulls > limit do
		table.remove(pulls)
	end
	return pulls
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@return string
local function search_query(view, opts)
	---@cast view AtlasGitLabPullsViewConfig
	local parts = { "is:" .. table.concat(selected_states(opts), ",") }
	for _, field in ipairs({
		"project",
		"group",
		"scope",
		"labels",
		"milestone",
		"author_username",
		"assignee_username",
	}) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", field:gsub("_username$", ""), tostring(value)))
		end
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end
	return table.concat(parts, " ")
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasGitLabPullsViewConfig
	local states = selected_states(opts)
	local api_states = {}
	if #states == 3 then
		api_states = { "all" }
	else
		for _, state in ipairs(states) do
			table.insert(api_states, API_STATES[state])
		end
	end
	local limit = math.min(100, math.max(1, tonumber(opts.pagelen) or 50))
	local request_opts = {
		force_load = opts.force_load == true,
		pagelen = limit,
	}
	if #api_states == 1 then
		request_opts.state = api_states[1]
		return pullrequests_api.fetch_pullrequests(view, request_opts, function(pulls, err)
			on_done(pulls, err and { err } or nil)
		end)
	end

	local scope = request_scope.new()
	local starts = {}
	for index, api_state in ipairs(api_states) do
		local planned_state = api_state
		starts[index] = function(done)
			return pullrequests_api.fetch_pullrequests(view, {
				force_load = request_opts.force_load,
				pagelen = request_opts.pagelen,
				state = planned_state,
			}, done)
		end
	end
	scope.all(starts, function(results, errors)
		local collected_errors = {}
		for index = 1, #api_states do
			if errors[index] then
				table.insert(collected_errors, errors[index])
			end
		end
		on_done(merge_results(results, limit), #collected_errors > 0 and collected_errors or nil)
	end)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	local requests = request_scope.new()
	requests.all({
		activity = function(done)
			return activity_api.fetch_activity(pr, opts, done)
		end,
		comments = function(done)
			return comments_api.fetch_conversation_comments(pr, opts, done)
		end,
	}, function(values, errors)
		if values.activity == nil and values.comments == nil then
			on_done(nil, errors.activity or errors.comments or "Failed to fetch conversation")
			return
		end
		local items = {}
		for _, comment in ipairs(values.comments or {}) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_on = comment.created_on or "",
				entity = comment,
			})
		end
		for _, event in ipairs(values.activity or {}) do
			table.insert(items, {
				id = table.concat({ "activity", event.date or "", event.kind or "" }, ":"),
				kind = "activity",
				created_on = event.date or "",
				entity = event,
			})
		end
		on_done(items, errors.activity or errors.comments)
	end)
	return requests
end

---@return AtlasGitLabPullsViewConfig[]
local function views()
	local options = config.domain_options("gitlab", "pulls") or {}
	local configured = options.views
	if not configured or #configured == 0 then
		configured = {
			{ name = "Assigned", key = "1", scope = "assigned_to_me" },
			{ name = "Created", key = "2", scope = "created_by_me" },
		}
	end
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitlab" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].project = repo
			resolved[i].scope = view.scope or "all"
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
	}
end

return {
	views = views,
	search_view = search_view,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			search_query = search_query,
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_reviewers = reviews_api.fetch_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.fetch_description,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_merge_checks = checks_api.fetch,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = author_completion.for_pulls,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = comments_api.add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			submit_review = reviews_api.submit,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			fetch_issues = repositories_api.fetch_issues,
			delete_branch = repositories_api.delete_branch,
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
			detail = detail_ui,
			repo_detail = repo_detail_ui,
		},
	},
}
