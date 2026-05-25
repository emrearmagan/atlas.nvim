local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
end

---@param status string|nil
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"
local function map_pipeline_state(status)
	local s = tostring(status or ""):lower()
	if s == "success" then
		return "SUCCESSFUL"
	elseif s == "failed" then
		return "FAILED"
	elseif s == "canceled" or s == "skipped" then
		return "STOPPED"
	end
	return "INPROGRESS"
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_builds(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:builds:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/pipelines", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local builds = {}
		for _, item in ipairs(type(result) == "table" and result or {}) do
			if type(item) == "table" then
				local id = item.id
				table.insert(builds, {
					name = string.format("Pipeline #%s", tostring(id or "")),
					state = map_pipeline_state(item.status),
					url = type(item.web_url) == "string" and item.web_url or nil,
					key = id and tostring(id) or nil,
				})
			end
		end
		service.set_memory_cache(cache_key, builds)
		on_done(builds, nil)
	end)
end

---@param builds PullsBuild[]
---@return PullsMergeCheck|nil
local function builds_check(builds)
	if type(builds) ~= "table" or #builds == 0 then
		return nil
	end
	local total, pass, fail, ip, stop = #builds, 0, 0, 0, 0
	for _, b in ipairs(builds) do
		local s = tostring(b.state or ""):upper()
		if s == "SUCCESSFUL" then
			pass = pass + 1
		elseif s == "FAILED" then
			fail = fail + 1
		elseif s == "INPROGRESS" then
			ip = ip + 1
		elseif s == "STOPPED" then
			stop = stop + 1
		end
	end
	local state, detail
	if fail > 0 then
		state = "failed"
		detail = string.format("%d of %d failed", fail, total)
	elseif ip > 0 then
		state = "inprogress"
		detail = string.format("%d of %d in progress", ip, total)
	elseif pass > 0 then
		state = "successful"
		detail = string.format("%d/%d successful", pass, total)
	else
		state = "muted"
		detail = string.format("All %d pipelines skipped", total)
	end
	return { key = "builds", state = state, label = "Pipelines", details = { detail } }
end

---@param raw table
---@return PullsMergeCheck[]
local function build_checks(raw)
	local checks = {}
	local dms = tostring(raw.detailed_merge_status or ""):lower()
	local has_conflicts = raw.has_conflicts == true

	if raw.draft == true or raw.work_in_progress == true then
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

	if raw.blocking_discussions_resolved == false or dms == "discussions_not_resolved" then
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
function M.get_merge_checks(pr, opts, on_done)
	opts = opts or {}
	local pending = 2
	local mr_raw, builds_result
	local first_err

	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if mr_raw == nil and builds_result == nil then
			on_done(nil, first_err or "Failed to fetch merge checks")
			return
		end
		local checks = build_checks(mr_raw or {})
		local bc = builds_check(builds_result)
		if bc then
			table.insert(checks, bc)
		end
		on_done(checks, nil)
	end

	local h_mr = mr_api.get_mr(pr, { force_refresh = opts.force_refresh == true }, function(fresh, err)
		if err then
			first_err = first_err or err
		elseif type(fresh) == "table" then
			mr_raw = type(fresh._raw) == "table" and fresh._raw or {}
		end
		finish()
	end)

	local h_builds = M.get_builds(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			builds_result = result
		end
		finish()
	end)

	return {
		cancel = function()
			if h_mr and h_mr.cancel then
				h_mr.cancel()
			end
			if h_builds and h_builds.cancel then
				h_builds.cancel()
			end
		end,
	}
end

return M
