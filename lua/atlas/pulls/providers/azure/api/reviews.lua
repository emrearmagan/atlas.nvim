local M = {}

local service = require("atlas.pulls.providers.azure.api.service")
local mapper = require("atlas.pulls.providers.azure.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	opts = opts or {}
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/reviewers",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
		tostring(pr.id)
	)
	local cache_key = "reviewers:" .. endpoint
	if not opts.force_refresh then
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
		local reviewers = mapper.to_reviewers(result.value)
		service.set_cache(cache_key, reviewers)
		on_done(reviewers, nil)
	end, { action = "Fetch pull request reviewers", repo = pr.repo_full_name, id = pr.id })
end

return M
