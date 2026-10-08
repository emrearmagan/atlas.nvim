local service = require("atlas.providers.bitbucket.client")

local M = {}

-- https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-mergeability-checks-get

local CHECK_STATES = {
	PASSED = "successful",
	FAILED = "failed",
	PENDING = "inprogress",
	SKIPPED = "muted",
	UNKNOWN = "warning",
}

---@type table<string, { label?: string, format?: function, failed_only?: boolean, group?: string }>
local CHECKS = {
	pullrequest_state_check = {
		failed_only = true,
		format = function(raw)
			return ({
				DRAFT = "Pull request is a draft",
				MERGED = "Pull request already merged",
				DECLINED = "Pull request was declined",
				SUPERSEDED = "Pull request was superseded",
			})[raw.state] or "Pull request cannot be merged"
		end,
	},
	current_user_permission_check = { label = "You cannot merge this pull request", failed_only = true },
	git_mergeability_check = {
		failed_only = true,
		format = function(raw)
			return raw.reason == "conflicts" and "Merge conflicts must be resolved" or "Branches cannot be merged"
		end,
	},
	merge_queue_check = {
		format = function(raw)
			local queue = raw.merge_queue
			if queue.state == "SUSPENDED" then
				return "Merge queue is suspended", queue.name .. " is not accepting pull requests"
			elseif queue.state == "DRAINING" then
				return "Merge queue is draining", queue.name .. " is not accepting new pull requests"
			elseif raw.queued then
				return "Pull request is queued", "Waiting in the " .. queue.name .. " merge queue"
			end
			return "Merge queue", queue.name .. ": " .. queue.state:lower()
		end,
	},
	minimum_approvals = {
		group = "reviews",
		format = function(_, observed, requirement)
			local count, minimum = observed.approval_count, requirement.minimum_approvals
			local description
			if count ~= nil and minimum ~= nil then
				description = string.format("%d of %d approvals received", count, minimum)
			end
			return "Approvals", description
		end,
	},
	minimum_default_reviewer_approvals = {
		group = "reviews",
		format = function(_, observed, requirement)
			local count, minimum =
				observed.default_reviewer_approval_count, requirement.minimum_default_reviewer_approvals
			local description
			if count ~= nil and minimum ~= nil then
				description = string.format("%d of %d default reviewer approvals received", count, minimum)
			end
			return "Default reviewer approvals", description
		end,
	},
	minimum_successful_builds = {
		group = "pipelines",
		format = function(raw, observed, requirement)
			local count, minimum = observed.successful_build_count, requirement.minimum_successful_builds
			local label = raw.status == "FAILED" and "More successful builds required" or "Successful builds"
			local description
			if count ~= nil and minimum ~= nil then
				description = string.format(
					"%d successful %s reported; %d required",
					count,
					count == 1 and "build" or "builds",
					minimum
				)
			end
			return label, description
		end,
	},
	failed_builds = {
		group = "pipelines",
		format = function(_, observed)
			local count = observed.failed_build_count
			if count == 0 then
				return "No failed builds"
			elseif count then
				return "Builds failed",
					string.format("%d %s reported failures", count, count == 1 and "build" or "builds")
			end
			return "Build failures"
		end,
	},
	in_progress_builds = {
		group = "pipelines",
		format = function(_, observed)
			local count = observed.in_progress_build_count
			if count == 0 then
				return "No builds in progress"
			elseif count then
				return "Builds are still in progress",
					string.format("%d %s not finished yet", count, count == 1 and "build has" or "builds have")
			end
			return "Builds in progress"
		end,
	},
	resolved_tasks = {
		failed_only = true,
		format = function(_, observed)
			local count = observed.unresolved_task_count
			local description
			if count ~= nil then
				description = string.format("%d %s unresolved", count, count == 1 and "task remains" or "tasks remain")
			end
			return "Tasks need resolving", description
		end,
	},
	no_changes_requested = { label = "Changes requested", failed_only = true },
	maximum_commits_behind = {
		format = function(raw)
			if raw.status == "FAILED" then
				return "Branch needs updating", "Update this branch with changes from the destination branch"
			elseif raw.status == "PASSED" then
				return "Branch is within the allowed limit"
			end
			return "Branch update status"
		end,
	},
}

local STATE_PRIORITY = { successful = 1, muted = 2, inprogress = 3, warning = 4, failed = 5 }

local GROUP_LABELS = {
	reviews = {
		successful = "Review requirements met",
		muted = "Review checks skipped",
		inprogress = "Review pending",
		warning = "Review status unavailable",
		failed = "Review required",
	},
	pipelines = {
		successful = "Build requirements met",
		muted = "Build checks skipped",
		inprogress = "Build checks pending",
		warning = "Build status unavailable",
		failed = "Build requirements not met",
	},
}

---@param value string
---@return string
local function readable(value)
	return (value:gsub("_", " "):gsub("^%l", string.upper))
end

---@param raw table
---@return PullsMergeCheck|nil
local function parse_check(raw)
	local definition = raw.check or {}
	local kind = definition.kind or raw.type
	local known = CHECKS[kind]
	if known and known.failed_only and raw.status ~= "FAILED" then
		return nil
	end
	local label = definition.name or (known and known.label) or readable(kind)
	local description
	if known and known.format then
		label, description = known.format(raw, raw.observed or {}, raw.requirement or {})
	end

	local details = {}
	if known and known.group then
		if description or known.group == "reviews" or raw.status ~= "PASSED" then
			local detail = description or label
			if raw.status ~= "PASSED" and raw.status ~= "FAILED" then
				detail = detail .. " (" .. readable(raw.status:lower()) .. ")"
			end
			if raw.status == "FAILED" and raw.blocking == false then
				detail = detail .. "; does not block merging"
			end
			table.insert(details, detail)
		end
	else
		if description then
			table.insert(details, description)
		end
		if raw.message and raw.message ~= "" then
			table.insert(details, raw.message)
		end
		if raw.status == "UNKNOWN" then
			table.insert(details, "Could not evaluate check")
		elseif raw.status == "SKIPPED" then
			table.insert(details, "Skipped")
		elseif raw.status == "PENDING" and #details == 0 then
			table.insert(details, "Check has not completed yet")
		end
		if raw.status == "FAILED" and raw.blocking == false then
			table.insert(details, "Does not block merging")
		end
	end

	return {
		key = definition.id and (raw.type .. ":" .. definition.id) or kind,
		state = CHECK_STATES[raw.status] or "warning",
		label = label,
		details = details,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local cache_key = string.format("bitbucket:merge-checks:%s:%s", pr.repo_full_name, pr.id)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repositories/%s/pullrequests/%s/mergeability/checks", pr.repo_full_name, pr.id)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if not result then
			on_done(nil, err or "Failed to load merge checks")
			return
		end

		---@type PullsMergeCheck[]
		local checks = {}
		local groups = {}
		for _, check in ipairs(result.values) do
			local parsed = parse_check(check)
			if parsed then
				local known = CHECKS[(check.check or {}).kind or check.type]
				if known and known.group then
					local group = groups[known.group]
					if not group then
						group = { key = known.group, state = "successful", details = {} }
						groups[known.group] = group
						table.insert(checks, group)
					end
					if STATE_PRIORITY[parsed.state] > STATE_PRIORITY[group.state] then
						group.state = parsed.state
					end
					group.label = GROUP_LABELS[known.group][group.state]
					vim.list_extend(group.details, parsed.details)
				else
					table.insert(checks, parsed)
				end
			end
		end
		service.set_cache(cache_key, checks)
		on_done(checks, nil)
	end, {
		action = "Fetch PR merge checks",
		repo = pr.repo_full_name,
		id = pr.id,
	})
end

return M
