local M = {}

local request_scope = require("atlas.core.requests")
local pipeline_utils = require("atlas.pulls.pipelines")
local pipelines = require("atlas.pulls.providers.bitbucket.api.pipelines")
local service = require("atlas.pulls.providers.bitbucket.api.service")

-- NOTE: Went hunting for full merge checks. Found two tickets and a browser API
-- that wants session cookies. Conflicts and builds it is.
-- https://jira.atlassian.com/browse/BCLOUD-22014
-- https://jira.atlassian.com/browse/BCLOUD-23964
--
-- https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-conflicts-get

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

	local requests = request_scope.new()
	requests.all({
		conflicts = function(done)
			local endpoint = string.format("/repositories/%s/pullrequests/%s/conflicts", pr.repo_full_name, pr.id)
			return service.fetch_all_values(endpoint, done, {
				action = "Fetch PR conflicts",
				repo = pr.repo_full_name,
				id = pr.id,
			})
		end,
		pipelines = function(done)
			return pipelines.fetch(pr, opts, done)
		end,
	}, function(results, errors)
		if errors.conflicts or errors.pipelines then
			on_done(nil, errors.conflicts or errors.pipelines)
			return
		end

		local has_conflicts = #results.conflicts.values > 0
		---@type PullsMergeCheck[]
		local checks = {
			{
				key = "conflicts",
				state = has_conflicts and "failed" or "successful",
				label = has_conflicts and "This branch has conflicts that must be resolved"
					or "No conflicts with destination branch",
			},
		}
		local pipeline_check = pipeline_utils.to_merge_check(results.pipelines, "Pipelines")
		if pipeline_check then
			table.insert(checks, pipeline_check)
		end
		service.set_cache(cache_key, checks)
		on_done(checks, nil)
	end)
	return requests
end

return M
