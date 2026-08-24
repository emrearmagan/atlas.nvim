local M = {}

local providers = require("atlas.pulls.providers")
local pipelines_api = require("atlas.pulls.providers.gitlab.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")

---@param pr GitLabPullRequest
---@param draft boolean
---@return PullsMergeCheck[]
local function parse_merge_checks(pr, draft)
	local checks = {}
	local dms = tostring(pr.detailed_merge_status or ""):lower()
	local has_conflicts = pr.has_conflicts == true

	if draft then
		table.insert(checks, {
			key = "draft",
			state = "warning",
			label = "This merge request is still a draft",
			details = { "Draft merge requests cannot be merged." },
		})
	end

	if has_conflicts or dms == "conflict" then
		table.insert(checks, {
			key = "conflicts",
			state = "failed",
			label = "This branch has conflicts that must be resolved",
			details = { "Conflicting files must be resolved before merging." },
		})
	elseif dms == "mergeable" then
		table.insert(checks, {
			key = "conflicts",
			state = "successful",
			label = "No conflicts with target branch",
		})
	end

	if pr.blocking_discussions_resolved == false or dms == "discussions_not_resolved" then
		table.insert(checks, {
			key = "discussions",
			state = "failed",
			label = "Unresolved discussions",
			details = { "Resolve all threads before merging." },
		})
	end

	if dms == "merge_request_blocked" then
		table.insert(checks, {
			key = "blocks",
			state = "failed",
			label = "Merge request dependencies must be merged",
		})
	end

	if dms == "requested_changes" then
		table.insert(checks, {
			key = "requested_changes",
			state = "failed",
			label = "Change requests must be approved by the requesting user",
		})
	end

	if dms == "not_approved" then
		table.insert(checks, {
			key = "approvals",
			state = "failed",
			label = "All required approvals must be given",
		})
	end

	if dms == "need_rebase" then
		table.insert(checks, {
			key = "rebase",
			state = "failed",
			label = "Source branch must be rebased onto target",
		})
	end

	if dms == "jira_association_missing" then
		table.insert(checks, {
			key = "jira",
			state = "failed",
			label = "Jira issue must be referenced",
		})
	end

	if dms == "external_status_checks" then
		table.insert(checks, {
			key = "external_checks",
			state = "failed",
			label = "External status checks must pass",
		})
	end

	if dms == "broken_status" then
		table.insert(checks, {
			key = "broken",
			state = "failed",
			label = "Merge status is broken",
		})
	end

	if dms == "preparing" then
		table.insert(checks, {
			key = "preparing",
			state = "inprogress",
			label = "Preparing merge",
		})
	end

	if dms == "ci_must_pass" or dms == "ci_still_running" then
		table.insert(checks, {
			key = "ci",
			state = dms == "ci_still_running" and "inprogress" or "warning",
			label = "Pipeline must pass",
			details = { "CI is required to merge." },
		})
	end

	return checks
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	opts = opts or {}
	local pending = 2
	local mr, pipelines_result
	local first_err

	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if mr == nil and pipelines_result == nil then
			on_done(nil, first_err or "Failed to fetch merge checks")
			return
		end
		local current = mr or pr
		---@cast current GitLabPullRequest
		local checks = parse_merge_checks(current, current.state == "draft")
		local bc = providers.pipelines_check(pipelines_result, "Pipelines")
		if bc then
			table.insert(checks, bc)
		end
		on_done(checks, nil)
	end

	local h_mr = pullrequests_api.fetch_pullrequest(
		pr,
		{ force_refresh = opts.force_refresh == true },
		function(fresh, err)
			if err then
				first_err = first_err or err
			elseif fresh then
				mr = fresh
			end
			finish()
		end
	)

	local h_pipelines = pipelines_api.fetch(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			pipelines_result = result
		end
		finish()
	end)

	return {
		cancel = function()
			if h_mr and h_mr.cancel then
				h_mr.cancel()
			end
			if h_pipelines and h_pipelines.cancel then
				h_pipelines.cancel()
			end
		end,
	}
end

return M
