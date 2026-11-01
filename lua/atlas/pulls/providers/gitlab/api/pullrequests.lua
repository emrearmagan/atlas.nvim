local M = {}

local service = require("atlas.providers.gitlab.client")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")
local reviews_api = require("atlas.pulls.providers.gitlab.api.reviews")
local users_api = require("atlas.providers.gitlab.users")
local json = require("atlas.core.json")

local MR_DETAILS_QUERY = [[
query($path:ID!,$iid:String!){
  currentUser{username}
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      description
      awardEmoji{nodes{name user{name username}}}
      subscribed
      assignees(first:100){nodes{id name username}}
      labels(first:100){nodes{name:title color text_color:textColor}}
    }
  }
}
]]

local MR_FIELDS = [[
fragment MergeRequestFields on MergeRequest {
  node_id:id
  iid
  reference(full:true)
  title
  state
  draft
  author{id name username}
  source_branch:sourceBranch
  target_branch:targetBranch
  diff_refs:diffRefs{base_sha:baseSha start_sha:startSha head_sha:headSha}
  user_notes_count:userNotesCount
  created_at:createdAt
  updated_at:updatedAt
  web_url:webUrl
  merge_status:mergeStatus
  detailed_merge_status:detailedMergeStatus
  reviewers(first:100){nodes{id name username}}
}
]]

local MR_SUMMARIES_QUERY = [[
query($path:ID!,$iids:[String!]!){
  project(fullPath:$path){
    mergeRequests(iids:$iids,first:100){
      nodes{...MergeRequestFields}
    }
  }
}
]] .. MR_FIELDS

local SCOPES = {
	assigned_to_me = { connection = "assignedMergeRequests", filter = "assigneeUsername" },
	created_by_me = { connection = "authoredMergeRequests", filter = "authorUsername" },
	reviews_for_me = { connection = "reviewRequestedMergeRequests", filter = "reviewerUsername" },
}

local FILTER_TYPES = {
	state = "MergeRequestState",
	sort = "MergeRequestSort",
	first = "Int",
	after = "String",
	labelName = "[String]",
	milestoneTitle = "String",
	search = "String",
	sourceBranches = "[String!]",
	targetBranches = "[String!]",
	authorUsername = "String",
	assigneeUsername = "String",
	reviewerUsername = "String",
	reviewStates = "[MergeRequestReviewState!]",
}

---@param root string
---@param connection string
---@param path string|nil
---@param filters table
---@return string, table
local function list_query(root, connection, path, filters)
	local definitions, arguments = {}, {}
	local variables = vim.tbl_extend("force", {}, filters)
	local names = vim.tbl_keys(filters)
	table.sort(names)
	for _, name in ipairs(names) do
		table.insert(definitions, "$" .. name .. ": " .. FILTER_TYPES[name])
		table.insert(arguments, name .. ": $" .. name)
	end

	if path then
		table.insert(definitions, "$path: ID!")
		variables.path = path
		root = root .. "(fullPath: $path)"
	end

	return string.format(
		[[query(%s) {
  source: %s {
    items: %s(%s) {
      nodes { ...MergeRequestFields }
      pageInfo { hasNextPage endCursor }
    }
  }
}
%s]],
		table.concat(definitions, ", "),
		root,
		connection,
		table.concat(arguments, ", "),
		MR_FIELDS
	),
		variables
end

---@param view AtlasGitLabPullsViewConfig
---@param opts { force_refresh?: boolean, pagelen: integer, state?: "opened"|"closed"|"merged"|"all", cursor?: string }
---@param on_done fun(page: PullsPage, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local path = view.project or view.group
	local root = view.project and "project" or view.group and "group" or "currentUser"
	local scope_name = view.scope or (path and "all" or "assigned_to_me")
	local scope = SCOPES[scope_name]
	if not scope and scope_name ~= "all" then
		on_done({ items = {} }, "Unknown GitLab MR scope: " .. scope_name)
		return nil
	end
	if not path and scope_name == "all" then
		on_done({ items = {} }, "GitLab MR scope 'all' requires a project or group")
		return nil
	end
	if path and type(path) ~= "string" then
		on_done({ items = {} }, "GitLab MR views require a project or group path, not a numeric ID")
		return nil
	end

	local state = opts.state or view.state or "opened"
	local order_by = (view.order_by or "updated_at"):gsub("_at$", "")
	local filters = {
		state = state,
		sort = (order_by .. "_" .. (view.sort or "desc")):upper(),
		first = opts.pagelen,
		after = opts.cursor,
		labelName = view.labels and vim.split(view.labels, ",", { plain = true }),
		milestoneTitle = view.milestone,
		authorUsername = view.author_username,
		assigneeUsername = view.assignee_username,
		search = view.search,
		sourceBranches = view.source_branch and { view.source_branch },
		targetBranches = view.target_branch and { view.target_branch },
		reviewStates = view.review_states,
	}
	if root == "currentUser" then
		-- The personal connection already selects the current user for this role.
		filters[scope.filter] = nil
	end

	local function fetch(username, done)
		if path and scope then
			filters[scope.filter] = username
		end

		local connection = path and "mergeRequests" or scope.connection
		local query, variables = list_query(root, connection, path, filters)
		local cache_key = "gitlab_pulls:merge_requests:gql:" .. query .. vim.inspect(variables)
		if not opts.force_refresh then
			local cached, ok = service.get_cache(cache_key)
			if ok then
				done(cached, nil)
				return nil
			end
		end

		return service.graphql(query, variables, function(result, err)
			if err then
				done({ items = {} }, err)
				return
			end
			local source = json.nilify(json.safe_table(result).source)
			local items = source and json.nilify(source.items)
			if not items then
				done({ items = {} }, "Unable to load GitLab merge requests" .. (path and ": " .. path or ""))
				return
			end
			local page = {
				items = mapper.to_pull_requests(items.nodes),
				next_cursor = items.pageInfo.hasNextPage and { [state] = items.pageInfo.endCursor } or nil,
			}
			service.set_cache(cache_key, page)
			done(page, nil)
		end, { action = "List MRs", project = view.project, group = view.group, scope = scope_name, state = state })
	end

	if not path or not scope then
		return fetch(nil, on_done)
	end

	local requests = request_scope.new()
	requests.run(users_api.fetch_user, function(user, err)
		if not user then
			on_done({ items = {} }, err or "Unable to load the current GitLab user")
			return
		end
		requests.run(function(done)
			return fetch(user.username, done)
		end, on_done)
	end)
	return requests
end

---@param pages table<string, PullsPage>
---@param view AtlasGitLabPullsViewConfig
---@return PullRequest[]
local function merge_results(pages, view)
	local pulls = {}
	local count = 0
	for _, page in pairs(pages) do
		count = count + 1
		vim.list_extend(pulls, page.items)
	end
	if count < 2 then
		return pulls
	end
	local fields = { updated_at = "updated_on", created_at = "created_on", title = "title" }
	local field = fields[view.order_by or "updated_at"]
	table.sort(pulls, function(left, right)
		if view.sort == "asc" then
			return left[field] < right[field]
		end
		return left[field] > right[field]
	end)
	return pulls
end

---@param view AtlasGitLabPullsViewConfig
---@param api_states ("opened"|"closed"|"merged"|"all")[]
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_states(view, api_states, opts, on_done)
	local states = {}
	for _, state in ipairs(api_states) do
		if opts.cursor == nil or opts.cursor[state] ~= nil then
			table.insert(states, state)
		end
	end

	local scope = request_scope.new()
	local starts = {}
	for _, state in ipairs(states) do
		local planned_state = state
		starts[planned_state] = function(done)
			return M.fetch_pullrequests(view, {
				force_refresh = opts.force_refresh,
				pagelen = opts.pagelen,
				state = planned_state,
				cursor = opts.cursor and opts.cursor[planned_state] or nil,
			}, done)
		end
	end
	scope.all(starts, function(pages, errors)
		---@cast pages table<string, PullsPage>
		local collected_errors = {}
		local next_cursor = {}
		for _, state in ipairs(states) do
			if errors[state] then
				table.insert(collected_errors, errors[state])
			elseif pages[state].next_cursor then
				next_cursor[state] = pages[state].next_cursor[state]
			end
		end
		on_done({
			items = merge_results(pages, view),
			next_cursor = next(next_cursor) and next_cursor or nil,
		}, #collected_errors > 0 and collected_errors or nil)
	end)
	return scope
end

---@param refs PullRequestRef[]
---@param opts PullsFetchOpts|nil
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	opts = opts or {}
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local iids_by_project = {}
	for _, ref in ipairs(refs) do
		local path = tostring(ref.repo_full_name or "")
		local iid = tonumber(ref.id)
		if path == "" or iid == nil then
			on_done({}, "Invalid MR identifier")
			return nil
		end
		iids_by_project[path] = iids_by_project[path] or {}
		table.insert(iids_by_project[path], iid)
	end

	local starts = {}
	for path, iids in pairs(iids_by_project) do
		starts[path] = function(done)
			local string_iids = vim.tbl_map(tostring, iids)
			table.sort(iids)
			local cache_key = string.format("gitlab_pulls:refs:%s!%s", path, table.concat(iids, ","))
			if not opts.force_refresh then
				local cached, ok = service.get_memory_cache(cache_key)
				if ok then
					done(cached, nil)
					return nil
				end
			end
			return service.graphql(MR_SUMMARIES_QUERY, { path = path, iids = string_iids }, function(result, err)
				if err then
					done(nil, err)
					return
				end
				local project = json.nilify(json.safe_table(result).project)
				local nodes = project and json.nilify(json.safe_table(json.safe_table(project).mergeRequests).nodes)
				if nodes == nil then
					done(nil, "Project or merge requests not found")
					return
				end
				local pulls = mapper.to_pull_requests(nodes)
				service.set_memory_cache(cache_key, pulls)
				done(pulls, nil)
			end, {
				action = "Fetch MR summaries",
				project_path = path,
				count = #iids,
			})
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(values, errors)
		local pulls = {}
		local err
		for path in pairs(iids_by_project) do
			err = err or errors[path]
			vim.list_extend(pulls, values[path] or {})
		end
		on_done(pulls, err)
	end)
	return requests
end

---@param pr PullRequestRef
---@param opts PullsFetchOpts|nil
---@param on_done fun(pr: PullRequestDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	opts = opts or {}
	local path = pr.repo_full_name
	local iid = tonumber(pr.id)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:details:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(MR_DETAILS_QUERY, { path = path, iid = tostring(iid) }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.safe_table(result).project
		local viewer = json.safe_str(json.safe_table(json.safe_table(result).currentUser).username)
		local details = mapper.to_pull_request_details(json.safe_table(project).mergeRequest, viewer)
		if details == nil then
			on_done(nil, "Merge request not found")
			return
		end
		service.set_memory_cache(cache_key, details)
		on_done(details, nil)
	end, {
		action = "Fetch MR details",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param pr PullRequest
---@param _ { force_refresh?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, _, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(json.safe_str(json.safe_table(result).description) or "", nil)
	end, {
		action = "Fetch MR description",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
local function invalidate_detail_caches(pr)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		return
	end
	service.delete_memory_cache(string.format("gitlab_pulls:details:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:reviewers:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:review_metadata:%s!%d", path, iid))
	service.clear_cache("gitlab_pulls:merge_requests:gql:")
end

---@param pr PullRequest
---@param payload table
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function update(pr, payload, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_detail_caches(pr)
		on_done(true, nil)
	end, {
		action = "Update MR",
		project_path = path,
		iid = iid,
	})
end

---@param path string
---@param iid integer
---@param subscribed boolean
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_subscription(path, iid, subscribed, on_done)
	local action = subscribed and "subscribe" or "unsubscribe"
	local endpoint = string.format("/projects/%s/merge_requests/%d/%s", service.url_encode(path), iid, action)
	return service.request("POST", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local value = type(result) == "table" and result.subscribed
		if type(value) ~= "boolean" then
			value = subscribed
		end
		on_done(value, nil)
	end, {
		action = subscribed and "Subscribe to MR" or "Unsubscribe from MR",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
---@param state_event "close"|"reopen"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(pr, state_event, on_done)
	return update(pr, { state_event = state_event }, on_done)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.decline(pr, on_done)
	return update(pr, { state_event = "close" }, on_done)
end

---@param pr PullRequest
---@param opts PullsUpdatePROpts
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_pr(pr, opts, on_done)
	local payload = {
		title = opts.title,
		description = opts.body,
		target_branch = opts.base,
		labels = opts.labels and table.concat(opts.labels, ",") or nil,
	}

	if opts.reviewers then
		local ids = {}
		for _, reviewer in ipairs(opts.reviewers) do
			ids[#ids + 1] = tonumber(reviewer.provider_id)
		end
		payload.reviewer_ids = #ids == 0 and { 0 } or ids
	end
	if opts.assignees then
		local ids = {}
		for _, user in ipairs(opts.assignees) do
			ids[#ids + 1] = tonumber(user.id)
		end
		payload.assignee_ids = #ids == 0 and { 0 } or ids
	end

	if opts.draft ~= nil then
		local title = (opts.title or pr.title):gsub("^%s*[Dd]raft:%s*", ""):gsub("^%s*WIP:%s*", "")
		if title == "" then
			on_done(false, "MR title is empty after stripping draft prefix")
			return nil
		end
		payload.title = opts.draft and "Draft: " .. title or title
	end

	return update(pr, payload, function(ok, err)
		if not ok then
			on_done(false, err)
			return
		end
		if payload.title then
			pr.title = payload.title
		end
		if opts.draft ~= nil then
			pr.state = opts.draft and "draft" or "open"
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	return M.update_pr(pr, { draft = draft }, on_done)
end

---@param opts { repo_slug: string, pr: PullRequest|nil }
---@param on_done fun(reviewers: PullsReviewerCandidate[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewer_candidates(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing project slug")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/members/all?per_page=100", service.url_encode(slug))
	local starts = {
		members = function(done)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch reviewer candidates",
				project_path = slug,
			})
		end,
	}
	if opts.pr then
		starts.current = function(done)
			return reviews_api.fetch_reviewers(opts.pr, { force_refresh = true }, done)
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(values, errors)
		local err = errors.members or errors.current
		if err then
			on_done(nil, err)
			return
		end

		local current_reviewers = values.current or {}
		local selected = {}
		for _, reviewer in ipairs(current_reviewers) do
			local username = tostring(reviewer.username or "")
			if reviewer.role == "reviewer" and username ~= "" then
				selected[username:lower()] = reviewer
			end
		end

		local reviewers = {}
		local candidates = {}
		for _, raw in ipairs(values.members or {}) do
			local username = tostring(raw.username or "")
			local id = tonumber(raw.id)
			if username ~= "" and id then
				local key = username:lower()
				candidates[key] = true
				table.insert(reviewers, {
					label = "@" .. username,
					provider_id = tostring(id),
					selected = selected[key] ~= nil,
				})
			end
		end
		for _, reviewer in ipairs(current_reviewers) do
			local key = tostring(reviewer.username or ""):lower()
			local raw_id = tostring(reviewer.provider_id or reviewer.id or "")
			local id = raw_id:match("([^/]+)$") or raw_id
			if selected[key] and not candidates[key] and tonumber(id) then
				table.insert(reviewers, {
					label = "@" .. tostring(reviewer.username),
					provider_id = id,
					selected = true,
				})
			end
		end
		on_done(reviewers, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param reviewers PullsReviewerCandidate[]
---@param _ PullsReviewerCandidate[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_reviewers(pr, reviewers, _, on_done)
	local ids = {}
	for _, reviewer in ipairs(reviewers) do
		local id = tonumber(reviewer.provider_id)
		if id then
			table.insert(ids, id)
		end
	end
	-- GitLab requires non-empty array; pass {0} to clear.
	local body = { reviewer_ids = (#ids == 0) and { 0 } or ids }
	return update(pr, body, on_done)
end

---@param pr PullRequest
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_assignees(pr, ids, on_done)
	local body = { assignee_ids = (#ids == 0) and { 0 } or ids }
	return update(pr, body, on_done)
end

---@param pr PullRequest
---@param opts PullsMergeOpts
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.merge(pr, opts, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	---@type table<string, boolean|string>
	local body = {
		squash = opts.method == "squash",
		should_remove_source_branch = opts.delete_source_branch == true,
	}
	if opts.subject ~= nil or opts.body ~= nil then
		local message = opts.subject or ""
		if opts.body and opts.body ~= "" then
			message = message .. (message ~= "" and "\n\n" or "") .. opts.body
		end
		body[opts.method == "squash" and "squash_commit_message" or "merge_commit_message"] = message
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/merge", service.url_encode(path), iid)
	return service.request("PUT", endpoint, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_detail_caches(pr)
		on_done(true, nil)
	end, {
		action = "Merge MR",
		project_path = path,
		iid = iid,
	})
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local path = tostring(opts.repo_slug or "")
	if path == "" then
		on_done(nil, "Missing repository slug")
		return nil
	end
	local source = tostring(opts.head or "")
	if source == "" then
		on_done(nil, "Missing source branch")
		return nil
	end
	local target = tostring(opts.base or "")
	if target == "" then
		on_done(nil, "Missing target branch")
		return nil
	end
	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		on_done(nil, "Title is required")
		return nil
	end

	-- GitLab marks drafts via the "Draft: " title prefix.
	if opts.draft == true and not (title:match("^%s*[Dd]raft:") or title:match("^%s*WIP:")) then
		title = "Draft: " .. title
	end

	local payload = {
		source_branch = source,
		target_branch = target,
		title = title,
		description = opts.body,
	}
	local reviewer_ids = {}
	for _, reviewer in ipairs(opts.reviewers or {}) do
		local id = tonumber(reviewer.provider_id)
		if id then
			table.insert(reviewer_ids, id)
		end
	end
	if #reviewer_ids > 0 then
		payload.reviewer_ids = reviewer_ids
	end

	local endpoint = string.format("/projects/%s/merge_requests", service.url_encode(path))

	local function submit()
		return service.request("POST", endpoint, payload, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local mr = mapper.to_pull_request(result)
			if mr == nil then
				on_done(nil, "GitLab returned an invalid merge request")
				return
			end
			local iid = tonumber(mr.id)
			service.clear_cache("gitlab_pulls:merge_requests:gql:")
			on_done({
				id = iid,
				url = mr.link.html,
				message = "Merge request created",
			}, nil)
		end, {
			action = "Create MR",
			path = path,
			source = source,
			target = target,
			draft = opts.draft == true,
		})
	end

	local head_slug = opts.head_repo_slug
	if head_slug and head_slug ~= "" and head_slug ~= path then
		return service.request(
			"GET",
			string.format("/projects/%s", service.url_encode(path)),
			nil,
			function(result, err)
				if err then
					on_done(nil, err)
					return
				end
				local project_id = type(result) == "table" and tonumber(result.id) or nil
				if not project_id then
					on_done(nil, "Could not resolve target project: " .. path)
					return
				end
				endpoint = string.format("/projects/%s/merge_requests", service.url_encode(head_slug))
				payload.target_project_id = project_id
				submit()
			end,
			{ action = "Resolve target project", path = path }
		)
	end

	return submit()
end

return M
