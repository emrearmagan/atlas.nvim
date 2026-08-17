local M = {}

---@class MemoryCacheEntry
---@field value any
---@field expires_at number|nil

---@type table<string, MemoryCacheEntry>
local store = {}
local order = {}
local MAX_ITEMS = 20

---@param key string
local function remove_from_order(key)
	for i, existing_key in ipairs(order) do
		if existing_key == key then
			table.remove(order, i)
			return
		end
	end
end

local function prune_expired()
	local now = os.time()
	for key, entry in pairs(store) do
		if entry.expires_at and now > entry.expires_at then
			store[key] = nil
			remove_from_order(key)
		end
	end

	while #order > MAX_ITEMS do
		local oldest_key = table.remove(order, 1)
		if oldest_key ~= nil then
			store[oldest_key] = nil
		end
	end
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set(key, value, ttl)
	prune_expired()
	local now = os.time()

	local expires_at = nil
	if ttl ~= nil and ttl > 0 then
		expires_at = now + ttl
	end

	remove_from_order(key)
	table.insert(order, key)
	store[key] = {
		value = value,
		expires_at = expires_at,
	}
	prune_expired()
end

---@param key string
---@return MemoryCacheEntry|nil
function M.get(key)
	prune_expired()

	local entry = store[key]
	if entry == nil then
		return nil
	end

	return entry
end

---@param key string
function M.delete(key)
	store[key] = nil
	remove_from_order(key)
end

---@param prefix string
function M.clear_prefix(prefix)
	for key in pairs(store) do
		if key:sub(1, #prefix) == prefix then
			M.delete(key)
		end
	end
end

function M.clear_all()
	store = {}
	order = {}
end

return M
