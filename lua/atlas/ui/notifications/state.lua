local M = {}

---@type table<string, AtlasNotification[]>
local by_provider = {}

---@param provider_id string
---@return AtlasNotification[]
function M.get(provider_id)
	return by_provider[provider_id] or {}
end

---@param provider_id string
---@param notifications AtlasNotification[]
function M.set(provider_id, notifications)
	by_provider[provider_id] = notifications
end

---@param provider_id string
---@param id string
function M.mark_local_read(provider_id, id)
	for _, n in ipairs(M.get(provider_id)) do
		if n.id == id then
			n.unread = false
			return
		end
	end
end

---@param provider_id string
---@param id string
function M.remove_local(provider_id, id)
	local notifications = M.get(provider_id)
	for i, n in ipairs(notifications) do
		if n.id == id then
			table.remove(notifications, i)
			return
		end
	end
end

return M
