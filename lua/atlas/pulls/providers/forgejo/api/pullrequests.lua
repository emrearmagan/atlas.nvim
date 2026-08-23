local service = require("atlas.providers.forgejo.client")
local config = require("atlas.config")
local pagination = require("atlas.providers.forgejo.pagination")
local mapper = require("atlas.pulls.providers.forgejo.api.mapper")
local request_scope = require("atlas.core.requests")

local api = {}

local function cache_scope()
	return string.format("forgejo:pulls:%s", service.base_url())
end

local function invalidate_list_cache()
	service.clear_cache(cache_scope() .. ":list:")
end

local function draft_prefix()
	local options = config.domain_options("forgejo", "pulls") or {}
	local prefix = vim.trim(options.draft_prefix or "")
	return prefix ~= "" and prefix or "WIP:"
end

local function without_draft_prefix(title)
	title = vim.trim(title)
	local prefixes = { draft_prefix(), "WIP:", "[WIP]" }
	for _, prefix in ipairs(prefixes) do
		if title:sub(1, #prefix):lower() == prefix:lower() then
			return vim.trim(title:sub(#prefix + 1))
		end
	end
	return title
end

local function with_draft_state(title, draft)
	local plain = without_draft_prefix(title)
	return draft and (draft_prefix() .. " " .. plain) or plain
end

---@param slug string
---@return string|nil
local function repo_endpoint(slug)
	local owner, repo = slug:match("^([^/]+)/([^/]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param pr PullRequest|PullRequestRef
---@return string|nil
local function pull_endpoint(pr)
	local endpoint = repo_endpoint(pr.repo_full_name)
	local id = tostring(pr.id)
	if endpoint and id:match("^%d+$") then
		return string.format("%s/pulls/%s", endpoint, id)
	end
end

---@param values PullsCreatePRReviewer[]|nil
---@return string[]
local function reviewer_logins(values)
	local result, seen = {}, {}
	for _, value in ipairs(values or {}) do
		local login = vim.trim(value.provider_id)
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(result, login)
		end
	end
	return result
end

---@param requests { method: string, endpoint: string, data: table|nil }[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function run_requests(requests, on_done)
	if #requests == 0 then
		on_done(true, nil)
		return nil
	end
	local scope = request_scope.new()
	local function run(index)
		local request = requests[index]
		if not request then
			on_done(true, nil)
			return
		end
		scope.run(function(done)
			return service.request(request.method, request.endpoint, request.data, done)
		end, function(_, err)
			if err then
				on_done(false, err)
				return
			end
			run(index + 1)
		end)
	end
	run(1)
	return scope
end

---@param opts PullsCreatePROpts
---@return { endpoint: string, payload: table, reviewers: string[] }|nil, string|nil
local function create_context(opts)
	local endpoint = repo_endpoint(opts.repo_slug)
	if not endpoint then
		return nil, "Invalid Forgejo repository"
	end
	local title = vim.trim(opts.title)
	local head = vim.trim(opts.head)
	local base = vim.trim(opts.base)
	if title == "" or head == "" or base == "" then
		return nil, "Title, head, and base are required"
	end
	if head == base then
		return nil, "Head and base branches must differ"
	end
	local context = {
		endpoint = endpoint,
		payload = {
			base = base,
			head = head,
			title = with_draft_state(title, opts.draft == true),
			body = opts.body,
		},
		reviewers = reviewer_logins(opts.reviewers),
	}
	return context, nil
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function create(opts, on_done)
	local context, err = create_context(opts)
	if not context then
		on_done(nil, err)
		return nil
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("POST", context.endpoint .. "/pulls", context.payload, done)
	end, function(raw, request_err)
		if request_err then
			on_done(nil, request_err)
			return
		end
		invalidate_list_cache()
		local result = { id = raw.number, url = raw.html_url, message = "Pull request created" }
		local warnings = {}
		if (raw.draft == true) ~= (opts.draft == true) then
			table.insert(warnings, "draft state could not be applied (check draft_prefix)")
		end
		local function update_message()
			result.message = "Pull request created"
			if #warnings > 0 then
				result.message = result.message .. "; " .. table.concat(warnings, "; ")
			end
		end
		update_message()
		if #context.reviewers == 0 then
			on_done(result, nil)
			return
		end
		requests.run(function(done)
			return service.request(
				"POST",
				string.format("%s/pulls/%s/requested_reviewers", context.endpoint, tostring(raw.number)),
				{ reviewers = context.reviewers, team_reviewers = {} },
				done
			)
		end, function(_, reviewers_err)
			if reviewers_err then
				table.insert(warnings, "reviewers could not be requested")
				update_message()
			end
			on_done(result, nil)
		end)
	end)
	return requests
end

api.create = create

local function detail_cache_key(pr)
	return string.format("%s:pr:%s:%s", cache_scope(), pr.repo_full_name, tostring(pr.id))
end

local function list_cache_key(view, opts, global)
	return cache_scope()
		.. ":list:"
		.. vim.json.encode({
			global = global,
			repo = view.repo,
			search = view.search,
			statuses = opts.statuses,
			pagelen = opts.pagelen,
		})
end

function api.fetch_user(on_done)
	local cache_key = cache_scope() .. ":user"
	local cached, ok = service.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end
	return service.request("GET", "/user", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local user = mapper.author(raw)
		local result = { id = user.id, name = user.name, username = user.username }
		service.set_cache(cache_key, result)
		on_done(result, nil)
	end)
end

---@param view AtlasForgejoPullsSearchConfig
---@param opts { statuses: string[], pagelen: number, force_load: boolean }
---@param on_done fun(pulls: PullRequest[]|nil, err: string|nil)
local function list(view, opts, on_done)
	local endpoint = repo_endpoint(view.repo)
	if not endpoint then
		on_done(nil, "Forgejo pull view requires repo = 'owner/repo'")
		return nil
	end
	local selected = {}
	for _, status in ipairs(opts.statuses) do
		selected[status:upper()] = true
	end
	local api_state = selected.OPEN and (selected.MERGED or selected.DECLINED) and "all"
		or (selected.OPEN and "open" or "closed")
	local search = vim.trim(tostring(view.search or "")):lower()

	---@param raw table
	---@return boolean
	local function accept(raw)
		local pull_state = mapper.pull_state(raw)
		local status = pull_state == "merged" and "MERGED" or pull_state == "declined" and "DECLINED" or "OPEN"
		if not selected[status] then
			return false
		end
		if search == "" then
			return true
		end
		local user = raw.user
		local haystack = table
			.concat({
				tostring(raw.number or ""),
				tostring(raw.title or ""),
				tostring(raw.body or ""),
				tostring(user.login or ""),
			}, "\n")
			:lower()
		return haystack:find(search, 1, true) ~= nil
	end

	local cache_key = list_cache_key(view, opts, false)
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return pagination.fetch_all(endpoint .. "/pulls", { state = api_state }, {
		max_items = opts.pagelen,
		accept = accept,
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local pulls = mapper.to_pull_requests(raw)
		service.set_cache(cache_key, pulls)
		on_done(pulls, nil)
	end)
end

---@param ref PullRequestRef
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequestDetails|nil, err: string|nil)
function api.get(ref, opts, on_done)
	local endpoint = pull_endpoint(ref)
	local repo = repo_endpoint(ref.repo_full_name)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	local cache_key = detail_cache_key(ref)
	if opts.force_load ~= true and opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	local requests = request_scope.new()
	requests.all({
		details = function(done)
			return service.request("GET", endpoint, nil, done)
		end,
		reactions = function(done)
			return pagination.fetch_all(
				string.format("%s/issues/%s/reactions", assert(repo), tostring(ref.id)),
				nil,
				nil,
				done
			)
		end,
	}, function(values, errors)
		local request_err = errors.details or errors.reactions
		if request_err then
			on_done(nil, request_err)
			return
		end
		local pr = mapper.to_pull_request_details(values.details)
		pr.reactions = mapper.reaction_counts(values.reactions)
		service.set_memory_cache(cache_key, pr)
		on_done(pr, nil)
	end)
	return requests
end

function api.description(pr, opts, on_done)
	opts = opts or {}
	if opts.force_refresh ~= true and pr.description ~= nil then
		on_done(pr.description, nil)
		return nil
	end
	return api.get(pr, opts, function(fresh, err)
		on_done(fresh and fresh.description or nil, err)
	end)
end

function api.review_data(pr, _, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return pagination.fetch_all(endpoint .. "/reviews", nil, {
		post_filtered = true,
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_review_data(pr, raw), nil)
	end)
end

function api.reviewers(pr, opts, on_done)
	return api.review_data(pr, opts, function(data, err)
		on_done(data and data.reviewers or nil, err)
	end)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string, pr: PullRequest|nil }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
function api.fetch_default_reviewers(opts, on_done)
	local endpoint = repo_endpoint(opts.repo_slug)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	local requests = request_scope.new()
	local starts = {
		candidates = function(done)
			return service.request("GET", endpoint .. "/reviewers", nil, function(raw, err)
				if err then
					done(nil, err)
					return
				end
				done(raw, nil)
			end)
		end,
		current_user = function(done)
			return api.fetch_user(done)
		end,
	}
	if opts.pr then
		starts.reviews = function(done)
			return api.review_data(opts.pr, {}, done)
		end
	end
	requests.all(starts, function(values, errors)
		local err = errors.candidates or errors.current_user or errors.reviews
		if err then
			on_done(nil, err)
			return
		end
		local excluded = {}
		local function exclude(login)
			login = vim.trim(tostring(login or "")):lower()
			if login ~= "" and login ~= "unknown" then
				excluded[login] = true
			end
		end
		exclude(values.current_user.username)
		local author = opts.pr and opts.pr.author or nil
		if author then
			exclude(author.username)
			exclude(author.nickname)
		end
		local selected = {}
		for _, reviewer in ipairs((values.reviews and values.reviews.reviewers) or {}) do
			local login = tostring(reviewer.provider_id or "")
			if login ~= "" and reviewer.decision == "pending" then
				selected[login] = true
			end
		end
		local reviewers, seen = {}, {}
		for _, value in ipairs(values.candidates) do
			local mapped = mapper.author(value)
			local key = mapped.username:lower()
			if not excluded[key] and not seen[key] then
				seen[key] = true
				table.insert(reviewers, {
					label = "@" .. mapped.username,
					provider_id = mapped.username,
					selected = selected[mapped.username] == true,
					default = false,
				})
			end
		end
		for login in pairs(selected) do
			if not excluded[login:lower()] and not seen[login:lower()] then
				table.insert(reviewers, { label = "@" .. login, provider_id = login, selected = true })
			end
		end
		table.sort(reviewers, function(left, right)
			return left.provider_id < right.provider_id
		end)
		on_done(reviewers, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param title string
---@param on_done fun(ok: boolean, err: string|nil)
local function patch_title(pr, title, on_done)
	local endpoint = pull_endpoint(pr)
	title = vim.trim(title)
	if not endpoint or title == "" then
		on_done(false, endpoint and "Title cannot be empty" or "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { title = title }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request_details(raw)
		pr.title = updated.title
		pr.state = updated.state
		pr._raw = updated._raw
		service.delete_memory_cache(detail_cache_key(pr))
		invalidate_list_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param title string
---@param expected_draft boolean
---@param error_message string
---@param on_done fun(ok: boolean, err: string|nil)
local function patch_title_checked(pr, title, expected_draft, error_message, on_done)
	local original_title = pr.title
	local requests = request_scope.new()
	requests.run(function(done)
		return patch_title(pr, title, done)
	end, function(ok, err)
		if not ok or err then
			on_done(false, err)
			return
		end
		if (pr.state == "draft") == expected_draft then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			return patch_title(pr, original_title, done)
		end, function(_, restore_err)
			if restore_err then
				error_message = error_message .. "; failed to restore title: " .. restore_err
			end
			on_done(false, error_message)
		end)
	end)
	return requests
end

function api.update_title(pr, title, on_done)
	if without_draft_prefix(title) == "" then
		on_done(false, "Title cannot be empty")
		return nil
	end
	local draft = pr.state == "draft"
	return patch_title_checked(
		pr,
		with_draft_state(title, draft),
		draft,
		"Forgejo did not preserve the draft state; configure an enabled draft_prefix",
		on_done
	)
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
function api.set_draft(pr, draft, on_done)
	local title = without_draft_prefix(pr.title)
	if title == "" then
		on_done(false, "Title cannot be empty")
		return nil
	end
	return patch_title_checked(
		pr,
		with_draft_state(title, draft),
		draft,
		"Forgejo did not change the draft state; configure an enabled draft_prefix",
		on_done
	)
end

---@param pr PullRequest
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
function api.update_description(pr, description, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { body = description }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request_details(raw)
		pr.description = updated.description
		pr._raw = updated._raw
		service.delete_memory_cache(detail_cache_key(pr))
		invalidate_list_cache()
		on_done(true, nil)
	end)
end

function api.update_reviewers(pr, selected, original, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	local selected_logins = reviewer_logins(selected)
	local original_logins = reviewer_logins(original)
	local selected_set, original_set = {}, {}
	for _, login in ipairs(selected_logins) do
		selected_set[login] = true
	end
	for _, login in ipairs(original_logins) do
		original_set[login] = true
	end
	local added, removed = {}, {}
	for _, login in ipairs(selected_logins) do
		if not original_set[login] then
			table.insert(added, login)
		end
	end
	for _, login in ipairs(original_logins) do
		if not selected_set[login] then
			table.insert(removed, login)
		end
	end
	local requests = {}
	if #added > 0 then
		table.insert(requests, {
			method = "POST",
			endpoint = endpoint .. "/requested_reviewers",
			data = { reviewers = added, team_reviewers = {} },
		})
	end
	if #removed > 0 then
		table.insert(requests, {
			method = "DELETE",
			endpoint = endpoint .. "/requested_reviewers",
			data = { reviewers = removed, team_reviewers = {} },
		})
	end
	return run_requests(requests, function(ok, err)
		if ok then
			service.delete_memory_cache(detail_cache_key(pr))
			invalidate_list_cache()
		end
		on_done(ok, err)
	end)
end

---@param slug string
---@param on_done fun(users: PullsAuthor[]|nil, err: string|nil)
function api.list_assignees(slug, on_done)
	local endpoint = repo_endpoint(slug)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return service.request("GET", endpoint .. "/assignees", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local result = {}
		for _, value in ipairs(raw) do
			table.insert(result, mapper.author(value))
		end
		on_done(result, nil)
	end)
end

---@param slug string
---@param on_done fun(labels: table[]|nil, err: string|nil)
function api.list_labels(slug, on_done)
	local endpoint = repo_endpoint(slug)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return pagination.fetch_all(endpoint .. "/labels", nil, nil, on_done)
end

---@param pr PullRequest
---@param assignees string[]
---@param on_done fun(ok: boolean, err: string|nil)
function api.update_assignees(pr, assignees, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { assignees = assignees }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request_details(raw)
		pr.assignees, pr._raw = updated.assignees, updated._raw
		service.delete_memory_cache(detail_cache_key(pr))
		invalidate_list_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param labels integer[]
---@param on_done fun(ok: boolean, err: string|nil)
function api.update_labels(pr, labels, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { labels = labels }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request_details(raw)
		pr.labels, pr._raw = updated.labels, updated._raw
		service.delete_memory_cache(detail_cache_key(pr))
		invalidate_list_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param username string
---@param subscribed boolean
---@param on_done fun(ok: boolean, err: string|nil)
function api.set_subscription(pr, username, subscribed, on_done)
	local endpoint = repo_endpoint(pr.repo_full_name)
	username = vim.trim(username)
	if not endpoint or username == "" or not tostring(pr.id):match("^%d+$") then
		on_done(false, "Invalid Forgejo subscription")
		return nil
	end
	local target =
		string.format("%s/issues/%s/subscriptions/%s", endpoint, tostring(pr.id), service.url_encode(username))
	return service.request(subscribed and "PUT" or "DELETE", target, nil, function(_, err)
		if not err then
			pr.is_subscribed = subscribed
			service.delete_memory_cache(detail_cache_key(pr))
		end
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
function api.subscription(pr, on_done)
	local endpoint = repo_endpoint(pr.repo_full_name)
	if not endpoint or not tostring(pr.id):match("^%d+$") then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return service.request(
		"GET",
		string.format("%s/issues/%s/subscriptions/check", endpoint, pr.id),
		nil,
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(raw.subscribed, nil)
		end
	)
end

---@param pr PullRequest
---@param state "open"|"closed"
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
function api.set_state(pr, state, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint or (state ~= "open" and state ~= "closed") then
		on_done(nil, endpoint and "Invalid pull request state" or "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { state = state }, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local updated = mapper.to_pull_request_details(raw)
		service.delete_memory_cache(detail_cache_key(pr))
		invalidate_list_cache()
		on_done(updated, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
function api.decline(pr, on_done)
	return api.set_state(pr, "closed", function(updated, err)
		on_done(updated ~= nil, err)
	end)
end

---@param pr PullRequest
---@param style "merge"|"rebase"|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function api.update_branch(pr, style, on_done)
	local endpoint = pull_endpoint(pr)
	style = style or "merge"
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	if style ~= "merge" and style ~= "rebase" then
		on_done(false, "Invalid update style")
		return nil
	end
	return service.request("POST", endpoint .. "/update" .. service.query({ style = style }), nil, function(_, err)
		if not err then
			service.delete_memory_cache(detail_cache_key(pr))
			invalidate_list_cache()
		end
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param opts { method: "merge"|"squash", delete_branch: boolean }
---@param on_done fun(ok: boolean, err: string|nil)
function api.merge(pr, opts, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	if opts.method ~= "merge" and opts.method ~= "squash" then
		on_done(false, "Invalid merge strategy")
		return nil
	end
	return service.request("POST", endpoint .. "/merge", {
		Do = opts.method,
		delete_branch_after_merge = opts.delete_branch == true,
		head_commit_id = pr.source.commit_hash ~= "" and pr.source.commit_hash or nil,
	}, function(_, err)
		if not err then
			service.delete_memory_cache(detail_cache_key(pr))
			invalidate_list_cache()
		end
		on_done(err == nil, err)
	end)
end

function api.list(view, opts, on_done)
	return list(view, opts, on_done)
end

---@param view { search: string|nil }
---@param opts { statuses: string[], pagelen: number, force_load: boolean }
---@param on_done fun(pulls: PullRequest[]|nil, err: string|nil)
function api.search_global(view, opts, on_done)
	local selected = {}
	for _, status in ipairs(opts.statuses) do
		selected[status:upper()] = true
	end
	local api_state = selected.OPEN and (selected.MERGED or selected.DECLINED) and "all"
		or (selected.OPEN and "open" or "closed")
	local cache_key = list_cache_key(view, opts, true)
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return pagination.fetch_all("/repos/issues/search", {
			["type"] = "pulls",
			q = vim.trim(tostring(view.search or "")),
			state = api_state,
		}, {
			max_items = opts.pagelen,
			accept = function(raw)
				local pr = mapper.to_search_pull_request(raw)
				local status = pr.state == "merged" and "MERGED" or pr.state == "declined" and "DECLINED" or "OPEN"
				return selected[status] == true
			end,
		}, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local prs = {}
		for _, value in ipairs(raw) do
			table.insert(prs, mapper.to_search_pull_request(value))
		end
		service.set_cache(cache_key, prs)
		on_done(prs, nil)
	end)
	return { cancel = requests.cancel }
end

return api
