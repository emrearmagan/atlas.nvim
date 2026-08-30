local M = {}

local service = require("atlas.providers.gitlab.client")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")
local reviews_api = require("atlas.pulls.providers.gitlab.api.reviews")
local json = require("atlas.core.json")

local MR_DETAILS_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      description
      subscribed
      assignees(first:100){nodes{id name username}}
      labels(first:100){nodes{name:title color text_color:textColor}}
    }
  }
}
]]

local MR_SUMMARIES_QUERY = [[
query($path:ID!,$iids:[String!]!){
  project(fullPath:$path){
    mergeRequests(iids:$iids,first:100){
      nodes{
        iid
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
    }
  }
}
]]

---@param params table<string, any>
---@return string
local function build_query(params)
	local parts = {}
	for k, v in pairs(params) do
		if type(v) == "table" then
			for _, item in ipairs(v) do
				if item ~= nil and item ~= "" then
					table.insert(parts, k .. "=" .. service.url_encode(tostring(item)))
				end
			end
		elseif v ~= nil and v ~= "" then
			table.insert(parts, k .. "=" .. service.url_encode(tostring(v)))
		end
	end
	table.sort(parts)
	if #parts == 0 then
		return ""
	end
	return "?" .. table.concat(parts, "&")
end

---@param view AtlasGitLabPullsViewConfig
---@param opts { force_refresh?: boolean, pagelen: integer, state?: "opened"|"closed"|"merged"|"all" }
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local project = view.project ~= nil and tostring(view.project) ~= "" and view.project or nil
	local group = view.group ~= nil and tostring(view.group) ~= "" and view.group or nil

	local params = {
		state = opts.state or "opened",
		per_page = tostring(opts.pagelen),
		order_by = view.order_by or "updated_at",
		sort = view.sort or "desc",
	}
	if project == nil and group == nil then
		params.scope = view.scope or "assigned_to_me"
	elseif view.scope then
		params.scope = view.scope
	end
	if view.labels then
		params.labels = view.labels
	end
	if view.milestone then
		params.milestone = view.milestone
	end
	if view.assignee_username then
		params.assignee_username = view.assignee_username
	end
	if view.author_username then
		params.author_username = view.author_username
	end
	if view.search and view.search ~= "" then
		params.search = view.search
	end
	for k, v in pairs(view.extra_params or {}) do
		if k ~= "state" then
			params[k] = v
		end
	end

	local endpoint
	if project ~= nil then
		endpoint =
			string.format("/projects/%s/merge_requests%s", service.url_encode(tostring(project)), build_query(params))
	elseif group ~= nil then
		endpoint =
			string.format("/groups/%s/merge_requests%s", service.url_encode(tostring(group)), build_query(params))
	else
		endpoint = "/merge_requests" .. build_query(params)
	end

	local cache_key = "gitlab_pulls:merge_requests:" .. endpoint
	if not opts.force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done({}, err)
			return
		end
		local pulls = mapper.to_pull_requests(result)
		service.set_cache(cache_key, pulls)
		on_done(pulls, nil)
	end, {
		action = "List MRs",
		endpoint = endpoint,
	})
end

---@param batches table<integer, PullRequest[]>
---@param limit integer
---@return PullRequest[]
local function merge_results(batches, limit)
	local pulls = {}
	for _, batch in pairs(batches) do
		vim.list_extend(pulls, batch)
	end
	table.sort(pulls, function(left, right)
		return left.updated_on > right.updated_on
	end)
	while #pulls > limit do
		table.remove(pulls)
	end
	return pulls
end

---@param view AtlasGitLabPullsViewConfig
---@param api_states ("opened"|"closed"|"merged"|"all")[]
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_states(view, api_states, opts, on_done)
	if #api_states == 1 then
		return M.fetch_pullrequests(view, {
			force_refresh = opts.force_refresh,
			pagelen = opts.pagelen,
			state = api_states[1],
		}, function(pulls, err)
			on_done(pulls, err and { err } or nil)
		end)
	end

	local scope = request_scope.new()
	local starts = {}
	for index, api_state in ipairs(api_states) do
		local planned_state = api_state
		starts[index] = function(done)
			return M.fetch_pullrequests(view, {
				force_refresh = opts.force_refresh,
				pagelen = opts.pagelen,
				state = planned_state,
			}, done)
		end
	end
	scope.all(starts, function(results, errors)
		---@cast results table<integer, PullRequest[]>
		local collected_errors = {}
		for index = 1, #api_states do
			if errors[index] then
				table.insert(collected_errors, errors[index])
			end
		end
		on_done(merge_results(results, opts.pagelen), #collected_errors > 0 and collected_errors or nil)
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
			local sorted_iids = vim.deepcopy(iids)
			table.sort(sorted_iids)
			local cache_key = string.format("gitlab_pulls:refs:%s!%s", path, table.concat(sorted_iids, ","))
			if not opts.force_refresh then
				local cached, ok = service.get_memory_cache(cache_key)
				if ok then
					done(cached, nil)
					return nil
				end
			end
			local string_iids = vim.tbl_map(tostring, iids)
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
		for path in pairs(iids_by_project) do
			if errors[path] then
				on_done({}, errors[path])
				return
			end
			vim.list_extend(pulls, values[path] or {})
		end
		on_done(pulls, nil)
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
		local details = mapper.to_pull_request_details(json.safe_table(project).mergeRequest)
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
---@param _opts { force_refresh?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, _opts, on_done)
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
---@param title string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_title(pr, title, on_done)
	return update(pr, { title = title }, on_done)
end

---@param pr PullRequest
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(pr, description, on_done)
	return update(pr, { description = description }, on_done)
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	local title = tostring(pr.title or ""):gsub("^%s*[Dd]raft:%s*", ""):gsub("^%s*WIP:%s*", "")
	if title == "" then
		on_done(false, "MR title is empty after stripping draft prefix")
		return nil
	end
	if draft then
		title = "Draft: " .. title
	end

	return update(pr, { title = title }, function(ok, err)
		if not ok then
			on_done(false, err)
			return
		end
		pr.title = title
		pr.state = draft and "draft" or "open"
		on_done(true, nil)
	end)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string, pr: PullRequest|nil }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
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
				action = "Fetch default reviewers",
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
					default = false,
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
					default = false,
				})
			end
		end
		on_done(reviewers, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param reviewers PullsCreatePRReviewer[]
---@param _original_reviewers PullsCreatePRReviewer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_reviewers(pr, reviewers, _original_reviewers, on_done)
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
---@param opts { squash: boolean|nil, should_remove_source_branch: boolean|nil, merge_commit_message: string|nil, squash_commit_message: string|nil }|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.merge(pr, opts, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	opts = opts or {}
	local body = {}
	if opts.squash ~= nil then
		body.squash = opts.squash == true
	end
	if opts.should_remove_source_branch ~= nil then
		body.should_remove_source_branch = opts.should_remove_source_branch == true
	end
	if opts.merge_commit_message and opts.merge_commit_message ~= "" then
		body.merge_commit_message = opts.merge_commit_message
	end
	if opts.squash_commit_message and opts.squash_commit_message ~= "" then
		body.squash_commit_message = opts.squash_commit_message
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

return M
