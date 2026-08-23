local providers = require("atlas.pulls.providers")
local pipeline_api = require("atlas.pulls.providers.forgejo.api.pipelines")
local pullrequests = require("atlas.pulls.providers.forgejo.api.pullrequests")
local service = require("atlas.providers.forgejo.client")
local request_scope = require("atlas.core.requests")

local M = {}

---@param raw table
local function branch_protection(raw)
	return {
		required_approvals = tonumber(raw.required_approvals),
		enable_status_check = raw.enable_status_check == true,
		status_check_contexts = raw.status_check_contexts,
		block_on_rejected_reviews = raw.block_on_rejected_reviews == true,
		block_on_official_review_requests = raw.block_on_official_review_requests == true,
		ignore_stale_approvals = raw.ignore_stale_approvals == true,
		block_on_outdated_branch = raw.block_on_outdated_branch == true,
	}
end

---@param pr PullRequest
---@return string|nil
local function repo_endpoint(pr)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

---@param pr PullRequest
---@param on_done fun(protection: table|false|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_branch_protection(pr, on_done)
	local base = repo_endpoint(pr)
	local branch = pr.destination.branch
	if not base or branch == "" then
		on_done(false, nil)
		return nil
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", base .. "/branches/" .. service.url_encode(branch), nil, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		if raw.protected ~= true then
			on_done(false, nil)
			return
		end
		local rule = vim.trim(tostring(raw.effective_branch_protection_name or ""))
		requests.run(function(done)
			return service.request("GET", base .. "/branch_protections/" .. service.url_encode(rule), nil, done)
		end, function(value, rule_err)
			if rule_err then
				if rule_err:match("^HTTP 404") then
					on_done(false, nil)
				else
					on_done(nil, rule_err)
				end
			else
				on_done(branch_protection(value), nil)
			end
		end)
	end)
	return requests
end

---@param reviewers PullsReviewer[]
---@param raw_reviews table[]
---@param protection table|false|nil
---@param pending_requests integer|nil
---@return PullsMergeCheck
local function reviewers_check(reviewers, raw_reviews, protection, pending_requests)
	local required = protection and math.max(0, tonumber(protection.required_approvals) or 0) or 0
	local blocks_changes = protection and protection.block_on_rejected_reviews == true
	local blocks_pending = protection and protection.block_on_official_review_requests == true
	local has_policy = required > 0 or blocks_changes or blocks_pending
	local approved, changes, pending = 0, 0, 0
	if protection then
		for _, review in ipairs(raw_reviews) do
			local state = tostring(review.state or ""):upper()
			if review.official == true then
				if
					state == "APPROVED"
					and review.dismissed ~= true
					and (protection.ignore_stale_approvals ~= true or review.stale ~= true)
				then
					approved = approved + 1
				elseif state == "REQUEST_CHANGES" and review.dismissed ~= true then
					changes = changes + 1
				elseif state == "REQUEST_REVIEW" and review.dismissed ~= true then
					pending = pending + 1
				end
			end
		end
	else
		pending = pending_requests or 0
		for _, reviewer in ipairs(reviewers) do
			if reviewer.decision == "approved" then
				approved = approved + 1
			elseif reviewer.decision == "changes_requested" then
				changes = changes + 1
			elseif pending_requests == nil then
				pending = pending + 1
			end
		end
	end

	if not protection then
		local details = { "No protected-branch review requirement" }
		if approved > 0 then
			table.insert(details, string.format("%d approval%s", approved, approved == 1 and "" or "s"))
		end
		if changes > 0 then
			table.insert(details, string.format("%d requested change%s", changes, changes == 1 and "" or "s"))
		end
		if pending > 0 then
			table.insert(details, string.format("%d requested review%s", pending, pending == 1 and "" or "s"))
		end
		return { key = "reviews", state = "muted", label = "Reviews", details = details }
	end

	local details = {}
	if required > 0 then
		table.insert(details, string.format("%d/%d required approvals", approved, required))
	elseif approved > 0 then
		table.insert(details, string.format("%d approval%s", approved, approved == 1 and "" or "s"))
	end
	if changes > 0 then
		table.insert(details, string.format("%d requested change%s", changes, changes == 1 and "" or "s"))
	end
	if pending > 0 then
		table.insert(details, string.format("%d pending review%s", pending, pending == 1 and "" or "s"))
	end
	local state = "successful"
	if not has_policy then
		state = "muted"
	elseif blocks_changes and changes > 0 then
		state = "failed"
	elseif approved < required or (blocks_pending and pending > 0) then
		state = "warning"
	end
	if #details == 0 then
		details = { has_policy and "Review policy satisfied" or "No review requirement" }
	end
	return { key = "reviews", state = state, label = "Reviews", details = details }
end

local STATUS_PRIORITY = {
	error = 0,
	failure = 1,
	warning = 2,
	pending = 3,
	success = 4,
	skipped = 5,
}

---@param pipelines PullsPipeline[]
---@return { context: string, state: string }[]
local function commit_statuses(pipelines)
	local result = {}
	for _, pipeline in ipairs(pipelines) do
		if #pipeline.jobs == 0 then
			table.insert(result, {
				context = tostring(pipeline.provider_context or ""),
				state = tostring(pipeline.provider_state or ""):lower(),
			})
		else
			for _, job in ipairs(pipeline.jobs) do
				table.insert(result, {
					context = tostring(job.provider_context or ""),
					state = tostring(job.provider_state or ""):lower(),
				})
			end
		end
	end
	return result
end

---@param values string[]
---@return string|nil
local function aggregate_status(values)
	local result
	for _, value in ipairs(values) do
		value = tostring(value):lower()
		if STATUS_PRIORITY[value] ~= nil then
			if result == nil or STATUS_PRIORITY[value] < STATUS_PRIORITY[result] then
				result = value
			end
		end
	end
	return result
end

---@param state string|nil
---@return "successful"|"failed"|"inprogress"|"warning"
local function check_state(state)
	if state == "success" then
		return "successful"
	elseif state == "failure" or state == "error" then
		return "failed"
	elseif state == "pending" then
		return "inprogress"
	end
	return "warning"
end

---@param pipelines PullsPipeline[]
---@param protection table|false|nil
---@return PullsMergeCheck|nil
local function pipelines_check(pipelines, protection)
	if not protection or protection.enable_status_check ~= true then
		return providers.pipelines_check(pipelines, "Pipelines")
	end
	local required = protection.status_check_contexts or {}
	local statuses = commit_statuses(pipelines)

	if #required == 0 then
		local states = {}
		for _, status in ipairs(statuses) do
			table.insert(states, status.state)
		end
		local state = aggregate_status(states)
		return {
			key = "pipelines",
			state = check_state(state),
			label = "Required status checks",
			details = { state and ("Combined status: " .. state) or "No commit status has succeeded" },
		}
	end

	local function matches(pattern, context)
		return vim.fn.match(context, vim.fn.glob2regpat(pattern)) >= 0
	end

	local passed, failed, running, warning, missing = 0, 0, 0, 0, 0
	for _, required_context in ipairs(required) do
		local states = {}
		for _, status in ipairs(statuses) do
			if matches(tostring(required_context), status.context) then
				table.insert(states, status.state)
			end
		end
		local state = aggregate_status(states)
		if state == "failure" or state == "error" then
			failed = failed + 1
		elseif state == "warning" then
			warning = warning + 1
		elseif state == "pending" then
			running = running + 1
		elseif state == "success" or state == "skipped" then
			passed = passed + 1
		else
			missing = missing + 1
		end
	end
	local details = { string.format("%d/%d required checks passed", passed, #required) }
	if failed > 0 then
		table.insert(details, string.format("%d failed", failed))
	end
	if running > 0 then
		table.insert(details, string.format("%d in progress", running))
	end
	if warning > 0 then
		table.insert(details, string.format("%d warning", warning))
	end
	if missing > 0 then
		table.insert(details, string.format("%d missing", missing))
	end
	local state = failed > 0 and "failed"
		or (warning > 0 and "warning")
		or (running > 0 and "inprogress")
		or (missing > 0 and "warning")
		or "successful"
	return { key = "pipelines", state = state, label = "Required status checks", details = details }
end

---@param pr PullRequest
---@param protection table|false|nil
---@return PullsMergeCheck|nil
local function up_to_date_check(pr, protection)
	if not protection or protection.block_on_outdated_branch ~= true then
		return nil
	end
	local raw = pr._raw
	local merge_base = tostring(raw.merge_base or "")
	local base_head = pr.destination.commit_hash
	if merge_base == "" or base_head == "" then
		return { key = "up_to_date", state = "muted", label = "Could not determine whether the branch is current" }
	end
	local current = merge_base == base_head
	return {
		key = "up_to_date",
		state = current and "successful" or "failed",
		label = current and "Branch is up to date" or "Branch must be updated with the target branch",
	}
end

---@param pr PullRequest
---@param opts table|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
function M.fetch_merge_checks(pr, opts, on_done)
	local pending = 4
	---@type PullRequest|nil
	local fresh
	---@type { reviewers: PullsReviewer[], raw: table[], pending_requests: integer }|nil
	local review_data
	---@type PullsPipeline[]|nil
	local pipelines
	---@type table|false|nil
	local protection
	local first_err
	local requests = request_scope.new()
	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if first_err then
			on_done(nil, first_err)
			return
		end
		local current = fresh
		local checks = {}
		if current.state == "draft" then
			table.insert(checks, {
				key = "draft",
				state = "warning",
				label = "This pull request is still a draft",
				details = { "Draft pull requests cannot be merged." },
			})
		end
		table.insert(
			checks,
			reviewers_check(review_data.reviewers, review_data.raw, protection, review_data.pending_requests)
		)
		local pipeline_check = pipelines_check(pipelines, protection)
		if pipeline_check then
			table.insert(checks, pipeline_check)
		end
		local up_to_date = up_to_date_check(current, protection)
		if up_to_date then
			table.insert(checks, up_to_date)
		end
		local raw = current._raw
		if raw.mergeable == true then
			table.insert(checks, { key = "conflicts", state = "successful", label = "No conflicts with base branch" })
		elseif raw.mergeable == false and current.state ~= "draft" then
			table.insert(checks, {
				key = "conflicts",
				state = "warning",
				label = "This pull request is not currently mergeable",
			})
		end
		on_done(checks, nil)
	end

	requests.run(function(done)
		return pullrequests.get(pr, opts or {}, done)
	end, function(value, err)
		fresh = value
		first_err = first_err or err
		finish()
	end)
	requests.run(function(done)
		return pullrequests.review_data(pr, opts or {}, done)
	end, function(value, err)
		review_data = value
		first_err = first_err or err
		finish()
	end)
	requests.run(function(done)
		return pipeline_api.fetch(pr, opts, done)
	end, function(value, err)
		pipelines = value
		first_err = first_err or err
		finish()
	end)
	requests.run(function(done)
		return fetch_branch_protection(pr, done)
	end, function(value, err)
		protection = value
		first_err = first_err or err
		finish()
	end)
	return requests
end

return M
