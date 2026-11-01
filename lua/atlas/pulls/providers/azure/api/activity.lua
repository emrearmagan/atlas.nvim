local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.azure.client")
local mapper = require("atlas.pulls.providers.azure.api.mapper")
local users = require("atlas.providers.azure.users")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(conversation: PullsConversation|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	opts = opts or {}
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/threads",
		service.url_encode(pr.repo.owner),
		service.url_encode(pr.repo.repo_name),
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

	local scope = request_scope.new()
	scope.all({
		threads = function(done)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch pull request conversation",
				repo = pr.repo_full_name,
				id = pr.id,
			})
		end,
		viewer = users.fetch_user,
	}, function(values, errors)
		if errors.threads then
			on_done(nil, errors.threads)
			return
		end
		local viewer = values.viewer and values.viewer.id
		local conversation = mapper.to_conversation(values.threads.value, pr, viewer)
		service.set_cache(cache_key, conversation)
		on_done(conversation, nil)
	end)
	return scope
end

return M
