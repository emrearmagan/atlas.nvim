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
local ui_detail = require("atlas.pulls.providers.github.ui.detail")
local ui_repo_detail = require("atlas.pulls.providers.github.ui.repo_detail")
local users_api = require("atlas.pulls.providers.github.api.users")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")

---@param opts PullsFetchOpts
---@return table<PullsStateFilter, boolean>
local function selected_states(opts)
	local selected = {}
	for _, state in ipairs(opts.states or { "open" }) do
		selected[state] = true
	end
	return selected
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@return string[]
local function search_queries(view, opts)
	---@cast view AtlasGitHubViewConfig
	local search = view.search or ""
	if search == "" then
		return {}
	end

	local base = search:find("is:pr", 1, true) and search or "is:pr " .. search
	if base:find("is:open", 1, true) or base:find("is:closed", 1, true) or base:find("is:merged", 1, true) then
		return { base }
	end
	local states = selected_states(opts)
	local open = states.open == true
	local merged = states.merged == true
	local declined = states.declined == true
	if open and merged and declined then
		return { base }
	end
	if merged and declined and not open then
		return { base .. " is:closed" }
	end

	local queries = {}
	if open then
		table.insert(queries, base .. " is:open")
	end
	if merged then
		table.insert(queries, base .. " is:merged")
	end
	if declined then
		table.insert(queries, base .. " is:closed -is:merged")
	end
	return #queries > 0 and queries or { base .. " is:open" }
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
	return table.concat(search_queries(view, opts), " OR ")
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	local queries = search_queries(view, opts)
	if #queries == 0 then
		vim.schedule(function()
			on_done({}, { "No search query configured for view" })
		end)
		return nil
	end

	local limit = math.min(100, math.max(1, tonumber(opts.pagelen) or 50))
	local request_opts = {
		force_load = opts.force_load == true,
		limit = limit,
	}
	if #queries == 1 then
		return pullrequests_api.search_prs(queries[1], on_done, request_opts)
	end

	local scope = request_scope.new()
	local starts = {}
	for index, query in ipairs(queries) do
		local planned_query = query
		starts[index] = function(done)
			return pullrequests_api.search_prs(planned_query, function(pulls, errors)
				done(pulls, errors and errors[1])
			end, request_opts)
		end
	end
	scope.all(starts, function(results, errors)
		local collected_errors = {}
		for index = 1, #queries do
			if errors[index] then
				table.insert(collected_errors, errors[index])
			end
		end
		on_done(merge_results(results, limit), #collected_errors > 0 and collected_errors or nil)
	end)
	return scope
end

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
	return pullrequests_api.get_pr(owner, repo, ref.id, on_done, { force_load = opts.force_load == true })
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
	views = views,
	search_view = search_view,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			search_query = search_query,
			fetch_pullrequests = fetch_pullrequests,
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
