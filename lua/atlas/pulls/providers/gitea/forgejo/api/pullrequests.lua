local service = require("atlas.providers.gitea.forgejo.client").pulls
local pagination = require("atlas.pulls.providers.gitea.forgejo.api.pagination")
local mapper = require("atlas.pulls.providers.gitea.forgejo.api.mapper")
local request_scope = require("atlas.core.requests")

local api = {}
local cache_namespace = "forgejo"

---@param value any
---@return boolean
local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if key ~= "__http_status" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
			return false
		end
	end
	return true
end

local function draft_prefix()
	local prefix = vim.trim(tostring(service.config().draft_prefix or ""))
	return prefix ~= "" and prefix or "WIP:"
end

local function without_draft_prefix(title)
	title = vim.trim(tostring(title or ""))
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
	local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param pr PullRequest|PullRequestRef
---@return string|nil
local function pull_endpoint(pr)
	if type(pr) ~= "table" then
		return nil
	end
	local endpoint = repo_endpoint(pr.repo_full_name)
	local id = tostring(pr.id or "")
	if endpoint and id:match("^%d+$") then
		return string.format("%s/pulls/%s", endpoint, id)
	end
end

---@param values PullsCreatePRReviewer[]|nil
---@return string[]
local function reviewer_logins(values)
	local result, seen = {}, {}
	for _, value in ipairs(values or {}) do
		local login = vim.trim(tostring(type(value) == "table" and value.provider_id or ""))
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
	local cancelled, active = false, nil
	local function run(index)
		if cancelled then
			return
		end
		local request = requests[index]
		if not request then
			on_done(true, nil)
			return
		end
		active = service.request(request.method, request.endpoint, request.data, function(_, err)
			if cancelled then
				return
			end
			if err then
				on_done(false, err)
				return
			end
			run(index + 1)
		end)
	end
	run(1)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
end

---@param opts PullsCreatePROpts|table
---@return { endpoint: string, payload: table, reviewers: string[] }|nil, string|nil
local function create_context(opts)
	opts = type(opts) == "table" and opts or {}
	local endpoint = repo_endpoint(opts.repo_slug)
	if not endpoint then
		return nil, "Invalid Forgejo repository"
	end
	local title = vim.trim(tostring(opts.title or ""))
	local head = vim.trim(tostring(opts.head or ""))
	local base = vim.trim(tostring(opts.base or ""))
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

	local cancelled, active = false, nil
	active = service.request("POST", context.endpoint .. "/pulls", context.payload, function(raw, request_err)
		if cancelled then
			return
		end
		if request_err or type(raw) ~= "table" or raw.number == nil then
			on_done(nil, request_err or "Invalid pull request response")
			return
		end
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
		active = service.request(
			"POST",
			string.format("%s/pulls/%s/requested_reviewers", context.endpoint, tostring(raw.number)),
			{ reviewers = context.reviewers, team_reviewers = {} },
			function(_, reviewers_err)
				if cancelled then
					return
				end
				if reviewers_err then
					table.insert(warnings, "reviewers could not be requested")
					update_message()
				end
				on_done(result, nil)
			end
		)
	end)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
end

api.create = create

local function cache_scope()
	return string.format("gitea:pulls:%s:%s", cache_namespace, service.base_url())
end

local function detail_cache_key(pr)
	return string.format("%s:pr:%s:%s", cache_scope(), tostring(pr.repo_full_name or ""), tostring(pr.id or ""))
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
	return service.request("GET", "/user", nil, function(raw, err)
		if err or type(raw) ~= "table" then
			on_done(nil, err or "Invalid user response")
			return
		end
		local user = mapper.author(raw)
		on_done({ id = user.id, name = user.name, username = user.username }, nil)
	end)
end

local function list(view, opts, on_done)
	opts = opts or {}
	if type(view) ~= "table" then
		on_done(nil, "Invalid Forgejo pull view")
		return nil
	end
	local endpoint = repo_endpoint(view.repo)
	if not endpoint then
		on_done(nil, "Forgejo pull view requires repo = 'owner/repo'")
		return nil
	end
	local selected = {}
	for _, status in ipairs(opts.statuses or { "OPEN" }) do
		selected[tostring(status):upper()] = true
	end
	local api_state = selected.OPEN and (selected.MERGED or selected.DECLINED) and "all"
		or (selected.OPEN and "open" or "closed")
	local search = vim.trim(tostring(view.search or "")):lower()

	---@param raw any
	---@return boolean
	local function accept(raw)
		if type(raw) ~= "table" then
			return false
		end
		local pull_state = mapper.pull_state(raw)
		local status = pull_state == "merged" and "MERGED" or pull_state == "declined" and "DECLINED" or "OPEN"
		if not selected[status] then
			return false
		end
		if search == "" then
			return true
		end
		local user = type(raw.user) == "table" and raw.user or {}
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
		max_items = math.max(1, tonumber(opts.pagelen) or 50),
		accept = accept,
		invalid_response = "Invalid pull request list response",
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local groups = mapper.to_groups(raw or {}, view.repo)
		if groups == nil then
			on_done(nil, "Invalid pull request list response")
			return
		end
		service.set_cache(cache_key, groups)
		on_done(groups, nil)
	end)
end

function api.get(ref, opts, on_done)
	local endpoint = pull_endpoint(ref)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	opts = opts or {}
	local cache_key = detail_cache_key(ref)
	if opts.force_load ~= true and opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("GET", endpoint, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local pr = mapper.to_pull_request(raw, ref.repo_full_name)
		if pr == nil then
			on_done(nil, "Invalid pull request response")
			return
		end
		service.set_memory_cache(cache_key, pr)
		on_done(pr, nil)
	end)
end

function api.description(pr, opts, on_done)
	return api.get(pr, opts, function(fresh, err)
		on_done(fresh and tostring(fresh.description or "") or nil, err)
	end)
end

function api.review_data(pr, _, on_done)
	local endpoint = pull_endpoint(pr)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return pagination.fetch_all(endpoint .. "/reviews", nil, {
		invalid_response = "Invalid pull request reviews response",
		post_filtered = true,
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end

		local latest_decision, latest_team_request = {}, {}
		for _, review in ipairs(raw or {}) do
			if type(review) ~= "table" then
				on_done(nil, "Invalid pull request reviews response")
				return
			end
			local review_id = tonumber(review.id)
			if review_id == nil then
				on_done(nil, "Invalid pull request reviews response")
				return
			end
			local state = tostring(review.state or ""):upper()
			local is_decision = state == "APPROVED" or state == "REQUEST_CHANGES" or state == "REQUEST_REVIEW"
			if is_decision then
				if type(review.user) == "table" then
					local mapped = mapper.author(review.user)
					local key = mapped.id ~= "" and mapped.id or mapped.username
					local previous = latest_decision[key]
					if key ~= "" and key ~= "unknown" and (not previous or review_id > previous.id) then
						latest_decision[key] = { id = review_id, raw = review }
					end
				elseif type(review.team) == "table" then
					local key = tostring(review.team.id or review.team.name or "")
					local previous = latest_team_request[key]
					if key ~= "" and (not previous or review_id > previous.id) then
						latest_team_request[key] = { id = review_id, raw = review }
					end
				end
			end
		end

		local reviewers = {}
		for _, decision in pairs(latest_decision) do
			local review = decision.raw
			if review.dismissed ~= true then
				local state = tostring(review.state or ""):upper()
				local user = mapper.author(review.user)
				table.insert(reviewers, {
					id = user.id,
					provider_id = user.username,
					name = user.name,
					username = user.username,
					nickname = user.nickname,
					decision = state == "APPROVED" and "approved"
						or (state == "REQUEST_CHANGES" and "changes_requested" or "pending"),
				})
			end
		end
		table.sort(reviewers, function(left, right)
			return left.provider_id < right.provider_id
		end)
		local pending_requests = 0
		for _, reviewer in ipairs(reviewers) do
			if reviewer.decision == "pending" then
				pending_requests = pending_requests + 1
			end
		end
		for _, request in pairs(latest_team_request) do
			if request.raw.dismissed ~= true and tostring(request.raw.state or ""):upper() == "REQUEST_REVIEW" then
				pending_requests = pending_requests + 1
			end
		end
		on_done({ raw = raw or {}, reviewers = reviewers, pending_requests = pending_requests }, nil)
	end)
end

function api.reviewers(pr, opts, on_done)
	return api.review_data(pr, opts, function(data, err)
		on_done(type(data) == "table" and data.reviewers or nil, err)
	end)
end

function api.fetch_default_reviewers(opts, on_done)
	opts = type(opts) == "table" and opts or {}
	local endpoint = repo_endpoint(opts.repo_slug)
	if not endpoint then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	local requests = request_scope.new()
	local starts = {
		candidates = function(done)
			return service.request("GET", endpoint .. "/reviewers", nil, function(raw, err)
				if err or not is_list(raw) then
					done(nil, err or "Invalid repository reviewers response")
					return
				end
				done(raw, nil)
			end)
		end,
		current_user = function(done)
			return api.fetch_user(done)
		end,
	}
	if type(opts.pr) == "table" then
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
		exclude(type(values.current_user) == "table" and values.current_user.username or nil)
		local author = type(opts.pr) == "table" and opts.pr.author or nil
		if type(author) == "table" then
			exclude(author.username)
			exclude(author.nickname)
		end
		local selected = {}
		for _, reviewer in ipairs(type(values.reviews) == "table" and values.reviews.reviewers or {}) do
			local login = tostring(reviewer.provider_id or "")
			if login ~= "" and reviewer.decision == "pending" then
				selected[login] = true
			end
		end
		local reviewers, seen = {}, {}
		for _, value in ipairs(values.candidates or {}) do
			local mapped = mapper.author(value)
			local key = mapped.username:lower()
			if mapped.username ~= "unknown" and not excluded[key] and not seen[key] then
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
	title = vim.trim(tostring(title or ""))
	if not endpoint or title == "" then
		on_done(false, endpoint and "Title cannot be empty" or "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", endpoint, { title = title }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request(raw, pr.repo_full_name)
		if updated == nil then
			on_done(false, "Invalid pull request response")
			return
		end
		pr.title = updated.title
		pr.state = updated.state
		pr._raw = updated._raw
		service.set_memory_cache(detail_cache_key(pr), pr)
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
	local title = without_draft_prefix(pr and pr.title or "")
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
	return service.request("PATCH", endpoint, { body = tostring(description or "") }, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local updated = mapper.to_pull_request(raw, pr.repo_full_name)
		if updated == nil then
			on_done(false, "Invalid pull request response")
			return
		end
		pr.description = updated.description
		pr._raw = updated._raw
		service.set_memory_cache(detail_cache_key(pr), pr)
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
		if err or not is_list(raw) then
			on_done(nil, err or "Invalid repository assignees response")
			return
		end
		local result = {}
		for _, value in ipairs(raw or {}) do
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
	return pagination.fetch_all(endpoint .. "/labels", nil, {
		invalid_response = "Invalid repository labels response",
	}, on_done)
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
		local updated = mapper.to_pull_request(raw, pr.repo_full_name)
		if not updated then
			on_done(false, "Invalid pull request response")
			return
		end
		pr.assignees, pr._raw = updated.assignees, updated._raw
		service.set_memory_cache(detail_cache_key(pr), pr)
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
		local updated = mapper.to_pull_request(raw, pr.repo_full_name)
		if not updated then
			on_done(false, "Invalid pull request response")
			return
		end
		pr.labels, pr._raw = updated.labels, updated._raw
		service.set_memory_cache(detail_cache_key(pr), pr)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param username string
---@param subscribed boolean
---@param on_done fun(ok: boolean, err: string|nil)
function api.set_subscription(pr, username, subscribed, on_done)
	local endpoint = repo_endpoint(pr.repo_full_name)
	username = vim.trim(tostring(username or ""))
	if not endpoint or username == "" or not tostring(pr.id or ""):match("^%d+$") then
		on_done(false, "Invalid Forgejo subscription")
		return nil
	end
	local target =
		string.format("%s/issues/%s/subscriptions/%s", endpoint, tostring(pr.id), service.url_encode(username))
	return service.request(subscribed and "PUT" or "DELETE", target, nil, function(_, err)
		if not err then
			pr.is_subscribed = subscribed
			service.set_memory_cache(detail_cache_key(pr), pr)
		end
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
function api.subscription(pr, on_done)
	local endpoint = repo_endpoint(pr.repo_full_name)
	if not endpoint or not tostring(pr.id or ""):match("^%d+$") then
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
			on_done(type(raw) == "table" and raw.subscribed == true, nil)
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
		local updated = mapper.to_pull_request(raw, pr.repo_full_name)
		if not updated then
			on_done(nil, "Invalid pull request response")
			return
		end
		service.set_memory_cache(detail_cache_key(updated), updated)
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
	opts = opts or {}
	if opts.method ~= "merge" and opts.method ~= "squash" then
		on_done(false, "Invalid merge strategy")
		return nil
	end
	local source = type(pr.source) == "table" and pr.source or {}
	return service.request("POST", endpoint .. "/merge", {
		Do = opts.method,
		delete_branch_after_merge = opts.delete_branch == true,
		head_commit_id = vim.trim(tostring(source.commit_hash or "")) ~= "" and source.commit_hash or nil,
	}, function(_, err)
		if not err then
			service.delete_memory_cache(detail_cache_key(pr))
		end
		on_done(err == nil, err)
	end)
end

function api.list(view, opts, on_done)
	return list(view, opts, on_done)
end

---@param view { search: string|nil }
---@param opts table
---@param on_done fun(groups: PullsGroup[]|nil, err: string|nil)
function api.search_global(view, opts, on_done)
	opts = opts or {}
	if type(view) ~= "table" then
		on_done(nil, "Invalid Forgejo global pull search")
		return nil
	end
	local selected = {}
	for _, status in ipairs(opts.statuses or { "OPEN" }) do
		selected[tostring(status):upper()] = true
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
			max_items = math.max(1, tonumber(opts.pagelen) or 50),
			accept = function(raw)
				local pr = mapper.to_search_pull_request(raw)
				if not pr then
					return false
				end
				local status = pr.state == "merged" and "MERGED" or pr.state == "declined" and "DECLINED" or "OPEN"
				return selected[status] == true
			end,
			invalid_response = "Invalid global pull request search response",
		}, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local refs, starts = {}, {}
		for index, value in ipairs(raw or {}) do
			local ref = mapper.to_search_pull_request(value)
			if not ref then
				on_done(nil, "Invalid global pull request search response")
				return
			end
			refs[index] = ref
			starts[tostring(index)] = function(done)
				return api.get(ref, { force_load = opts.force_load }, done)
			end
		end
		requests.all(starts, function(values, errors)
			local prs = {}
			for index = 1, #refs do
				local key = tostring(index)
				local pr = values[key]
				if errors[key] or not pr then
					on_done(nil, errors[key] or "Invalid pull request response")
					return
				end
				table.insert(prs, pr)
			end
			local groups = mapper.group_pull_requests(prs)
			if not groups then
				on_done(nil, "Invalid global pull request search response")
				return
			end
			service.set_cache(cache_key, groups)
			on_done(groups, nil)
		end)
	end)
	return { cancel = requests.cancel }
end

return api
