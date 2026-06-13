local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")

---@param opts { force_load?: boolean, limit?: number }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(opts, on_done)
	opts = opts or {}
	local limit = tonumber(opts.limit) or 100

	local cache_key = string.format("gitea_pulls:notifications:all:limit:%d", limit)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("notifications?all=true&limit=%d", limit)
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			on_done({}, nil)
			return
		end

		local notifications = {}
		for _, raw in ipairs(result) do
			local n = mapper.to_notification(raw)
			if n then
				table.insert(notifications, n)
			end
		end

		cli.set_cache(cache_key, notifications, 60)
		on_done(notifications, nil)
	end, {
		action = "Fetch notifications",
	})
end

---@param thread_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_read(thread_id, on_done)
	local endpoint = string.format("notifications/threads/%s", tostring(thread_id))
	return cli.api("PATCH", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, {
		action = "Mark notification read",
		thread_id = thread_id,
	})
end

return M
