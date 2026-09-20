local M = {}

local service = require("atlas.pulls.providers.azure.api.service")
local mapper = require("atlas.pulls.providers.azure.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	opts = opts or {}
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/threads",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
		tostring(pr.id)
	)
	local cache_key = "conversation:" .. endpoint
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
		local items = mapper.to_conversation(result.value, pr)
		service.set_cache(cache_key, items)
		on_done(items, nil)
	end, { action = "Fetch pull request conversation", repo = pr.repo_full_name, id = pr.id })
end

return M
