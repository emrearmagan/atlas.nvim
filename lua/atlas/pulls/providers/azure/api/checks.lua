local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.azure.client")
local utils = require("atlas.ui.shared.utils")

local states = {
	approved = "successful",
	queued = "inprogress",
	running = "inprogress",
	rejected = "failed",
	broken = "failed",
	notApplicable = "muted",
}

local merge_states = {
	succeeded = { state = "successful", label = "No merge conflicts" },
	conflicts = { state = "failed", label = "Merge conflicts must be resolved" },
	queued = { state = "inprogress", label = "Checking merge conflicts" },
	rejectedByPolicy = { state = "failed", label = "Merge rejected by policy" },
	failure = { state = "failed", label = "Merge check failed" },
	notSet = { state = "muted", label = "Merge status unavailable" },
}

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	---@cast pr AzurePullRequest
	local endpoint = string.format("/%s/_apis/policy/evaluations", service.url_encode(pr.repo.owner))
		.. service.build_query({
			artifactId = string.format("vstfs:///CodeReview/CodeReviewId/%s/%s", pr.project_id, pr.id),
		})
	-- The artifactId seems weird but see here: https://learn.microsoft.com/en-us/rest/api/azure/devops/policy/evaluations/list?view=azure-devops-rest-7.1#:~:text=To%20generate%20an%20artifact%20ID
	local cache_key = "merge-checks:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local merge = merge_states[pr.merge_status or "notSet"]
		local checks = { { key = "merge", state = merge.state, label = merge.label } }
		for _, evaluation in ipairs(result.value) do
			local configuration = evaluation.configuration
			local name = json.safe_str(configuration.settings.displayName)
			local state = states[evaluation.status]
			local show_details = state == "inprogress" or state == "failed"
			local completed = json.safe_str(evaluation.completedDate)
			local timestamp = completed or json.safe_str(evaluation.startedDate)
			local timestamp_label = completed and "Completed " or "Evaluation started "
			local check_state = state
			if state == "failed" and not configuration.isBlocking then
				check_state = "warning"
			end
			local label = configuration.type.displayName
			if name and name ~= "" then
				label = label .. ": " .. name
			end
			local details = nil
			if show_details and timestamp then
				details = { timestamp_label .. utils.relative_time_text(timestamp) }
			end
			table.insert(checks, {
				key = evaluation.evaluationId,
				state = check_state,
				label = label,
				details = details,
			})
		end
		service.set_cache(cache_key, checks)
		on_done(checks, nil)
	end, { action = "Fetch pull request policies", repo = pr.repo_full_name, id = pr.id }, "7.1-preview.1")
end

return M
