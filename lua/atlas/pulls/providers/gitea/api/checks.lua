local pagination = require("atlas.providers.gitea.pagination")
local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.gitea.client")

local M = {}

---@param reviews table[]
---@param branch table
---@return PullsMergeCheck
local function reviews_check(reviews, branch)
	local opinions, requests = {}, {}
	for index, review in ipairs(reviews) do
		if review.official == true and review.dismissed ~= true then
			local state = tostring(review.state or ""):upper()
			local user = type(review.user) == "table" and review.user or {}
			local team = type(review.team) == "table" and review.team or {}
			local key = tostring(user.id or user.login or team.id or team.name or "")
			local id = tonumber(review.id) or index
			if key ~= "" and (state == "APPROVED" or state == "REQUEST_CHANGES") then
				if opinions[key] == nil or id > opinions[key].id then
					opinions[key] = { id = id, state = state, stale = review.stale == true }
				end
			elseif key ~= "" and state == "REQUEST_REVIEW" then
				if requests[key] == nil or id > requests[key].id then
					requests[key] = { id = id }
				end
			end
		end
	end

	local approved, changes, pending = 0, 0, 0
	for _, opinion in pairs(opinions) do
		if opinion.state == "APPROVED" and not opinion.stale then
			approved = approved + 1
		elseif opinion.state == "REQUEST_CHANGES" and not opinion.stale then
			changes = changes + 1
		end
	end
	for key, request in pairs(requests) do
		if opinions[key] == nil or request.id > opinions[key].id then
			pending = pending + 1
		end
	end

	local required = branch.protected == true and math.max(0, tonumber(branch.required_approvals) or 0) or 0
	local details = {}
	if required > 0 then
		table.insert(details, string.format("%d/%d required approvals", approved, required))
	else
		table.insert(details, "No protected-branch approval requirement")
		if approved > 0 then
			table.insert(details, string.format("%d current approval%s", approved, approved == 1 and "" or "s"))
		end
	end
	if changes > 0 then
		table.insert(details, string.format("%d reviewer%s requested changes", changes, changes == 1 and "" or "s"))
	end
	if pending > 0 then
		table.insert(details, string.format("%d pending official review%s", pending, pending == 1 and "" or "s"))
	end

	local state = "muted"
	if required > 0 then
		state = approved >= required and "successful" or "warning"
	end
	if changes > 0 or pending > 0 then
		state = "warning"
	end
	return { key = "reviews", state = state, label = "Reviews", details = details }
end

---@param values string[]
---@return "successful"|"failed"|"inprogress"|"missing"
local function aggregate_status(values)
	if #values == 0 then
		return "missing"
	end
	local pending = false
	for _, value in ipairs(values) do
		local state = tostring(value):lower()
		if state == "failure" or state == "error" or state == "warning" then
			return "failed"
		elseif state ~= "success" and state ~= "skipped" then
			pending = true
		end
	end
	return pending and "inprogress" or "successful"
end

---@param pattern string
---@param context string
---@return boolean
local function matches_context(pattern, context)
	if pattern == context then
		return true
	end
	local ok, regex = pcall(vim.fn.glob2regpat, pattern)
	return ok and vim.fn.match(context, regex) >= 0
end

---@param statuses table[]
---@param branch table
---@return PullsMergeCheck|nil
local function status_check(statuses, branch)
	if branch.protected ~= true or branch.enable_status_check ~= true then
		return nil
	end

	local required = type(branch.status_check_contexts) == "table" and branch.status_check_contexts or {}
	local passed, failed, running, missing = 0, 0, 0, 0
	if #required == 0 then
		for _, status in ipairs(statuses) do
			local state = aggregate_status({ tostring(status.status or "") })
			if state == "successful" then
				passed = passed + 1
			elseif state == "failed" then
				failed = failed + 1
			else
				running = running + 1
			end
		end
		if #statuses == 0 then
			missing = 1
		end
	else
		for _, pattern in ipairs(required) do
			local states = {}
			for _, status in ipairs(statuses) do
				if matches_context(tostring(pattern), tostring(status.context or "")) then
					table.insert(states, tostring(status.status or ""))
				end
			end
			local state = aggregate_status(states)
			if state == "successful" then
				passed = passed + 1
			elseif state == "failed" then
				failed = failed + 1
			elseif state == "inprogress" then
				running = running + 1
			else
				missing = missing + 1
			end
		end
	end

	local total = #required > 0 and #required or #statuses
	local details = { string.format("%d/%d required checks passed", passed, total) }
	if failed > 0 then
		table.insert(details, string.format("%d failed", failed))
	end
	if running > 0 then
		table.insert(details, string.format("%d in progress", running))
	end
	if missing > 0 then
		table.insert(details, string.format("%d missing", missing))
	end
	local state = failed > 0 and "failed" or ((running > 0 or missing > 0) and "inprogress" or "successful")
	return { key = "pipelines", state = state, label = "Required status checks", details = details }
end

---@param endpoint string
---@param ctx table
---@param on_done fun(statuses: table[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_statuses(endpoint, ctx, on_done)
	local requests = request_scope.new()
	local statuses = {}
	local page = 1
	local function fetch_page()
		requests.run(function(done)
			return service.request("GET", endpoint .. service.query({ limit = 50, page = page }), nil, done, ctx)
		end, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local values = type(raw) == "table" and type(raw.statuses) == "table" and raw.statuses or {}
			vim.list_extend(statuses, values)
			if #values < 50 then
				on_done(statuses, nil)
				return
			end
			page = page + 1
			fetch_page()
		end)
	end
	fetch_page()
	return requests
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, _opts, on_done)
	local owner, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	local id = tonumber(pr.id)
	if not owner or not id then
		on_done(nil, "Invalid Gitea pull request")
		return nil
	end

	local repo_slug = owner .. "/" .. repo
	local base = string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	local pull_endpoint = string.format("%s/pulls/%d", base, id)
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", pull_endpoint, nil, done, {
			action = string.format("Fetch %s#%d merge state", repo_slug, id),
			repo = repo_slug,
			pr_id = id,
		})
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local base_ref = type(raw.base) == "table" and tostring(raw.base.ref or "") or ""
		local head_sha = type(raw.head) == "table" and tostring(raw.head.sha or "") or ""
		if base_ref == "" or head_sha == "" then
			on_done(nil, "Gitea pull request revisions are unavailable")
			return
		end

		requests.all({
			branch = function(done)
				return service.request("GET", base .. "/branches/" .. service.url_encode(base_ref), nil, done, {
					action = string.format("Fetch %s base branch policy", repo_slug),
					repo = repo_slug,
					branch = base_ref,
				})
			end,
			reviews = function(done)
				return pagination.fetch_all(pull_endpoint .. "/reviews", nil, nil, done, {
					action = string.format("Fetch %s#%d reviews", repo_slug, id),
					repo = repo_slug,
					pr_id = id,
				})
			end,
			statuses = function(done)
				return fetch_statuses(base .. "/commits/" .. service.url_encode(head_sha) .. "/status", {
					action = string.format("Fetch %s#%d required statuses", repo_slug, id),
					repo = repo_slug,
					pr_id = id,
				}, done)
			end,
		}, function(values, errors)
			local request_err = errors.branch or errors.reviews or errors.statuses
			if request_err then
				on_done(nil, request_err)
				return
			end
			local branch = type(values.branch) == "table" and values.branch or {}
			local reviews = type(values.reviews) == "table" and values.reviews or {}
			local statuses = type(values.statuses) == "table" and values.statuses or {}
			local checks = {}
			if raw.draft == true then
				table.insert(checks, {
					key = "draft",
					state = "warning",
					label = "This pull request is still a draft",
					details = { "Draft pull requests cannot be merged." },
				})
			end
			table.insert(checks, reviews_check(reviews, branch))
			local required_statuses = status_check(statuses, branch)
			if required_statuses then
				table.insert(checks, required_statuses)
			end
			if raw.mergeable == true then
				table.insert(
					checks,
					{ key = "conflicts", state = "successful", label = "No conflicts with base branch" }
				)
			elseif raw.mergeable == false and raw.draft ~= true then
				table.insert(checks, {
					key = "conflicts",
					state = "warning",
					label = "This pull request is not currently mergeable",
				})
			end
			on_done(checks, nil)
		end)
	end)
	return requests
end

return M
