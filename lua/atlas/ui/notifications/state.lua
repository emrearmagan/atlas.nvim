---@class AtlasNotificationsState
---@field notifications AtlasNotification[]
---@field unread_count integer
---@field is_loading boolean
---@field error string|nil
---@field last_provider_id string|nil
local M = {
	notifications = {},
	unread_count = 0,
	is_loading = false,
	error = nil,
	last_provider_id = nil,
}

---@param notifications AtlasNotification[]|nil
function M.set_notifications(notifications)
	M.notifications = notifications or {}
	local unread = 0
	for _, n in ipairs(M.notifications) do
		if n.unread then
			unread = unread + 1
		end
	end
	M.unread_count = unread
end

---@param id string
function M.mark_local_read(id)
	for _, n in ipairs(M.notifications or {}) do
		if n.id == id and n.unread then
			n.unread = false
			M.unread_count = math.max(0, M.unread_count - 1)
			return
		end
	end
end

---@param id string
function M.remove_local(id)
	for i, n in ipairs(M.notifications or {}) do
		if n.id == id then
			if n.unread then
				M.unread_count = math.max(0, M.unread_count - 1)
			end
			table.remove(M.notifications, i)
			return
		end
	end
end

function M.reset()
	M.notifications = {}
	M.unread_count = 0
	M.is_loading = false
	M.error = nil
end

return M
