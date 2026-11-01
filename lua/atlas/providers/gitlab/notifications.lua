local M = {}
---@cast M AtlasNotificationsCapability

local client = require("atlas.providers.gitlab.client")

local TARGET_KIND = {
	MergeRequest = "pr",
	Issue = "issue",
	["DesignManagement::Design"] = "issue",
}

---@param raw table
---@return AtlasNotification
local function normalize(raw)
	local target_type = tostring(raw.target_type or "")
	local target = type(raw.target) == "table" and raw.target or {}
	local project = type(raw.project) == "table" and raw.project or {}
	local repo = tostring(project.path_with_namespace or project.name_with_namespace or "")

	local subtitle_parts = {}
	if repo ~= "" then
		table.insert(subtitle_parts, repo)
	end
	local action = tostring(raw.action_name or ""):gsub("_", " ")
	if action ~= "" then
		table.insert(subtitle_parts, action)
	end

	local updated_at = tostring(raw.updated_at or raw.created_at or "")

	return {
		id = tostring(raw.id or ""),
		title = tostring(target.title or raw.body or ""),
		subtitle = table.concat(subtitle_parts, "  "),
		timestamp = updated_at ~= "" and updated_at or nil,
		kind = raw.action_name == "build_failed" and "checks" or TARGET_KIND[target_type],
		unread = tostring(raw.state or "") == "pending",
		url = type(raw.target_url) == "string" and raw.target_url or nil,
	}
end

---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(opts, on_done)
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_memory_cache("gitlab:todos")
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return client.request("GET", "/todos?per_page=100&state=pending", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local notifications = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			table.insert(notifications, normalize(raw))
		end
		client.set_memory_cache("gitlab:todos", notifications, 60)
		on_done(notifications, nil)
	end, {
		action = "Fetch notifications",
	})
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_done(id, on_done)
	local endpoint = string.format("/todos/%s/mark_as_done", tostring(id))
	return client.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		client.delete_memory_cache("gitlab:todos")
		on_done(true, nil)
	end, {
		action = "Mark notification done",
		notification_id = id,
	})
end

---@param notification AtlasNotification
---@return boolean
function M.open(notification)
	if notification.url == nil then
		return false
	end
	if notification.kind == "checks" then
		require("atlas.commands.pipelines").open(notification.url)
	elseif notification.kind == "pr" or notification.kind == "issue" then
		require("atlas.commands.open").open(notification.url)
	else
		return false
	end
	return true
end

return M
