local service = require("atlas.pulls.providers.bitbucket.api.service")

local M = {}

-- NOTE: Went hunting for full merge checks. Found two tickets and a browser API
-- that wants session cookies. Conflicts it is.
-- https://jira.atlassian.com/browse/BCLOUD-22014
-- https://jira.atlassian.com/browse/BCLOUD-23964
--
-- https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-conflicts-get

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local cache_key = string.format("bitbucket:merge-requirements:%s:%s", pr.repo_full_name, pr.id)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repositories/%s/pullrequests/%s/conflicts", pr.repo_full_name, pr.id)
	return service.fetch_all_values(endpoint, function(result, err)
		if not result then
			on_done(nil, err or "Failed to load conflicts")
			return
		end

		local has_conflicts = #result.values > 0
		---@type PullsMergeCheck[]
		local checks = {
			{
				key = "conflicts",
				state = has_conflicts and "failed" or "successful",
				label = has_conflicts and "This branch has conflicts that must be resolved"
					or "No conflicts with destination branch",
			},
		}
		service.set_cache(cache_key, checks)
		on_done(checks, nil)
	end, {
		action = "Fetch PR conflicts",
		repo = pr.repo_full_name,
		id = pr.id,
	})
end

return M
