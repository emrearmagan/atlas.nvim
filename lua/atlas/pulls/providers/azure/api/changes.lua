local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/commits",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
		tostring(pr.id)
	)
	local cache_key = "commits:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local commits = {}
	local scope = request_scope.new()
	local context = { action = "Fetch pull request commits", repo = pr.repo_full_name, id = pr.id }

	---@param continuation_token string|nil
	local function fetch_page(continuation_token)
		local query = service.build_query({ ["$top"] = 100, continuationToken = continuation_token })
		scope.run(function(done)
			return service.request("GET", endpoint .. query, nil, done, context)
		end, function(result, err, headers)
			if err then
				on_done(nil, err)
				return
			end
			for _, raw in ipairs(result.value) do
				table.insert(commits, {
					hash = raw.commitId,
					short_hash = raw.commitId:sub(1, 8),
					message = raw.comment,
					author_name = raw.author.name,
					date = raw.author.date,
					html_url = raw.remoteUrl,
				})
			end
			local next_token = headers["x-ms-continuationtoken"]
			if next_token then
				fetch_page(next_token)
				return
			end
			service.set_cache(cache_key, commits)
			on_done(commits, nil)
		end)
	end

	fetch_page(nil)
	return scope
end

return M
