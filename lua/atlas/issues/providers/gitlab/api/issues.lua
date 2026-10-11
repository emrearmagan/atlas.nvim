local M = {}

local service = require("atlas.providers.gitlab.client")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")
local users_api = require("atlas.providers.gitlab.users")
local json = require("atlas.core.json")
local LIST_CACHE_PREFIX = "gitlab:issues:list:gql:"

local ISSUE_LABELS_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      labels(first: 100) { nodes { title color } }
    }
  }
}
]]

local ISSUE_ASSIGNEES_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      assignees(first: 100) { nodes { id username name } }
    }
  }
}
]]

local ISSUE_DETAILS_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      title
      description
      assignees(first: 100) { nodes { id username name } }
      labels(first: 100) { nodes { title color } }
      milestone { id title }
    }
  }
}
]]

local ISSUES_QUERY = [[
query(
  %s
  $state: IssuableState
  $sort: IssueSort
  $first: Int
  $after: String
  $iids: [String!]
  $labelName: [String]
  $milestoneTitle: [String]
  $assigneeUsernames: [String!]
  $authorUsername: String
  $search: String
) {
  %s
  items: issues(
    state: $state
    sort: $sort
    first: $first
    after: $after
    iids: $iids
    labelName: $labelName
    milestoneTitle: $milestoneTitle
    assigneeUsernames: $assigneeUsernames
    authorUsername: $authorUsername
    search: $search
  ) {
    nodes {
      iid
      reference(full: true)
      title
      state
      issue_type: type
      confidential
      subscribed
      author { id username name }
      assignees(first: 1) { nodes { id username name } }
      web_url: webUrl
      due_date: dueDate
      created_at: createdAt
      updated_at: updatedAt
      closed_at: closedAt
      user_notes_count: userNotesCount
    }
    pageInfo { hasNextPage endCursor }
  }
  %s
}
]]

---@param path string
---@param iid integer
local function invalidate_issue(path, iid)
	service.delete_memory_cache(string.format("gitlab:issue-details:%s#%d", path, iid))
	service.clear_cache(LIST_CACHE_PREFIX)
end

---@param view AtlasGitLabIssuesSearchConfig
---@param opts { force_refresh?: boolean, pagelen: integer, cursor?: string, iids?: integer[] }
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_issues(view, opts, on_done)
	local scope = view.scope or "all"
	if scope ~= "all" and scope ~= "assigned_to_me" and scope ~= "created_by_me" then
		on_done({ items = {} }, "Unknown GitLab issue scope: " .. scope)
		return nil
	end

	local order_by = view.order_by or "updated_at"
	if order_by == "created_at" or order_by == "updated_at" then
		order_by = order_by:sub(1, -4)
	end
	local variables = {
		state = view.state or "opened",
		sort = (order_by .. "_" .. (view.sort or "desc")):upper(),
		first = opts.pagelen,
		after = opts.cursor,
		iids = opts.iids and vim.tbl_map(tostring, opts.iids),
		labelName = view.labels and vim.split(view.labels, ",", { plain = true }),
		milestoneTitle = view.milestone and { view.milestone },
		assigneeUsernames = view.assignee_username and { view.assignee_username },
		authorUsername = view.author_username,
		search = view.search,
	}
	if view.project then
		local project_id = tonumber(view.project)
		if project_id then
			variables.projectIds = { "gid://gitlab/Project/" .. project_id }
		else
			variables.projectPaths = { view.project }
		end
	end

	local function fetch(done)
		local query
		if view.project then
			query = ISSUES_QUERY:format(
				"$projectIds: [ID!], $projectPaths: [String!]",
				"projects(ids: $projectIds, fullPaths: $projectPaths, first: 1) { nodes {",
				"} }"
			)
		else
			query = ISSUES_QUERY:format("", "", "")
		end
		local cache_key = LIST_CACHE_PREFIX .. query .. vim.inspect(variables)
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
			local source = json.safe_table(result)
			if view.project then
				source = json.safe_table(json.safe_table(source.projects).nodes)[1]
			end
			local items = json.nilify(json.safe_table(source).items)
			if not items then
				done({ items = {} }, "Unable to load GitLab issues" .. (view.project and ": " .. view.project or ""))
				return
			end
			-- TODO: GitLab's GraphQL Issue type does not expose parent refs. Fetch them through WorkItems.
			local page = {
				items = normalizer.to_issues_list(items.nodes),
				next_cursor = items.pageInfo.hasNextPage and items.pageInfo.endCursor or nil,
			}
			service.set_cache(cache_key, page)
			done(page, nil)
		end, { action = "List issues", project = view.project, scope = scope })
	end

	if scope == "all" then
		return fetch(on_done)
	end

	local requests = request_scope.new()
	requests.run(users_api.fetch_user, function(user, err)
		if not user then
			on_done({ items = {} }, err or "Unable to load the current GitLab user")
			return
		end
		if scope == "assigned_to_me" then
			variables.assigneeUsernames = { user.username }
		else
			variables.authorUsername = user.username
		end
		requests.run(fetch, on_done)
	end)
	return requests
end

---@param refs IssueRef[]
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	opts = opts or {}
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local iids_by_project = {}
	for _, ref in ipairs(refs) do
		local path, iid = normalizer.parse_key(ref.key)
		if path == "" or iid == nil then
			on_done({}, "Invalid issue key: " .. tostring(ref.key))
			return nil
		end
		iids_by_project[path] = iids_by_project[path] or {}
		table.insert(iids_by_project[path], iid)
	end

	local starts = {}
	for path, iids in pairs(iids_by_project) do
		for offset = 1, #iids, 100 do
			local batch = {}
			for index = offset, math.min(offset + 99, #iids) do
				batch[#batch + 1] = iids[index]
			end
			starts[path .. "#" .. offset] = function(done)
				return M.list_issues({
					project = path,
					scope = "all",
					state = "all",
				}, {
					force_refresh = opts.force_refresh == true,
					pagelen = #batch,
					iids = batch,
				}, function(page, err)
					done(page.items, err)
				end)
			end
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(values, errors)
		local issues = {}
		local err
		for key in pairs(starts) do
			err = err or errors[key]
			vim.list_extend(issues, values[key] or {})
		end
		on_done(issues, err)
	end)
	return requests
end

---@param ref IssueRef
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	opts = opts or {}
	local key = ref.key
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local cache_key = string.format("gitlab:issue-details:%s#%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(ISSUE_DETAILS_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.safe_table(data).project
		local raw = json.safe_table(project).issue
		local details = normalizer.to_issue_details(raw)
		if details then
			service.set_memory_cache(cache_key, details)
			on_done(details, nil)
			return
		end
		on_done(nil, "Issue not found")
	end, {
		action = "Fetch issue",
		path = path,
		iid = iid,
		transport = "graphql",
	})
end

---@param key string
---@param on_done fun(assignees: AtlasUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignees(key, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	return service.graphql(ISSUE_ASSIGNEES_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(data).project
		local issue = json.nilify(json.safe_table(project).issue)
		if issue == nil then
			on_done(nil, "Issue not found")
			return
		end

		local assignees = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(issue.assignees).nodes)) do
			local user = normalizer.to_user(raw)
			if user and tonumber(user.id) then
				table.insert(assignees, user)
			end
		end
		on_done(assignees, nil)
	end, {
		action = "Fetch issue assignees",
		path = path,
		iid = iid,
	})
end

---@param issue GitLabIssue
---@param subscribed boolean
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_subscription(issue, subscribed, on_done)
	local action = subscribed and "subscribe" or "unsubscribe"
	local endpoint =
		string.format("/projects/%s/issues/%d/%s", service.url_encode(issue.project_path), issue.iid, action)
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
		action = subscribed and "Subscribe to issue" or "Unsubscribe from issue",
		project_path = issue.project_path,
		iid = issue.iid,
	})
end

---@param key string
---@param state_event "close"|"reopen"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state_event, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end
	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, { state_event = state_event }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_issue(path, iid)
		on_done(true, nil)
	end, {
		action = "Issue state change",
		path = path,
		iid = iid,
		state = state_event,
	})
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local payload = {}
	if diff.add and #diff.add > 0 then
		payload.add_labels = table.concat(diff.add, ",")
	end
	if diff.remove and #diff.remove > 0 then
		payload.remove_labels = table.concat(diff.remove, ",")
	end
	if next(payload) == nil then
		on_done(true, nil)
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_issue(path, iid)
		on_done(true, nil)
	end, {
		action = "Update labels",
		path = path,
		iid = iid,
		add = diff.add,
		remove = diff.remove,
	})
end

---@param key string
---@param on_done fun(labels: IssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue_labels(key, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	return service.graphql(ISSUE_LABELS_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(data).project
		local issue = json.nilify(json.safe_table(project).issue)
		if issue == nil then
			on_done(nil, "Issue not found")
			return
		end

		local labels = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(issue.labels).nodes)) do
			local name = json.safe_str(raw.title)
			if name then
				table.insert(labels, { name = name, color = json.safe_str(raw.color) })
			end
		end
		on_done(labels, nil)
	end, {
		action = "Fetch issue labels",
		path = path,
		iid = iid,
	})
end

---@param key string
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_assignee_ids(key, ids, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local payload = { assignee_ids = ids }
	if #ids == 0 then
		-- Empty array unassigns; GitLab requires assignee_ids = [0] for clearing
		payload = { assignee_ids = { 0 } }
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_issue(path, iid)
		on_done(true, nil)
	end, {
		action = "Set assignees",
		path = path,
		iid = iid,
		ids = ids,
	})
end

---@param opts { project_path: string, title: string, description: string|nil, assignee_ids: integer[]|nil, labels: string[]|nil, milestone_id: integer|nil, due_date: string|nil, confidential: boolean|nil }
---@param on_done fun(result: GitLabIssueEditorResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	local path = tostring(opts.project_path or "")
	if path == "" then
		on_done(nil, "Missing project_path")
		return nil
	end
	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		on_done(nil, "Title is required")
		return nil
	end

	local payload = { title = title }
	if opts.description and opts.description ~= "" then
		payload.description = opts.description
	end
	if opts.assignee_ids and #opts.assignee_ids > 0 then
		payload.assignee_ids = opts.assignee_ids
	end
	if opts.labels and #opts.labels > 0 then
		payload.labels = table.concat(opts.labels, ",")
	end
	if opts.milestone_id then
		payload.milestone_id = opts.milestone_id
	end
	if opts.due_date and opts.due_date ~= "" then
		payload.due_date = opts.due_date
	end
	if opts.confidential == true then
		payload.confidential = true
	end

	local endpoint = string.format("/projects/%s/issues", service.url_encode(path))

	return service.request("POST", endpoint, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local issue = normalizer.to_issue(result)
		if issue == nil then
			on_done(nil, "GitLab returned an invalid issue")
			return
		end
		service.clear_cache(LIST_CACHE_PREFIX)
		on_done({
			key = issue.key,
			iid = issue.iid,
			url = issue.url,
		}, nil)
	end, {
		action = "Create issue",
		path = path,
		title = title,
	})
end

---@param key string
---@param fields { title: string, description: string, labels: string[], assignee_ids: integer[], milestone_id?: integer }
---@param on_done fun(result: GitLabIssueEditorResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_issue(key, fields, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local payload = {
		title = fields.title,
		description = fields.description,
		labels = table.concat(fields.labels, ","),
		assignee_ids = #fields.assignee_ids > 0 and fields.assignee_ids or { 0 },
		milestone_id = fields.milestone_id or 0,
	}
	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		invalidate_issue(path, iid)
		on_done({ key = key, iid = iid, url = json.safe_str(json.safe_table(result).web_url) }, nil)
	end, {
		action = "Update issue",
		path = path,
		iid = iid,
	})
end

return M
