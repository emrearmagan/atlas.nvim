local M = {}

---@class CacheEntry
---@field key string|nil
---@field value any
---@field expires_at number | nil

local atlas_cache_root = vim.fn.stdpath("cache") .. "/atlas"
local cache_root = atlas_cache_root .. "/cache"
local PRUNE_INTERVAL_SEC = 300
local last_prune_at = 0

local function ensure_cache_dir()
	if vim.fn.isdirectory(cache_root) == 0 then
		vim.fn.mkdir(cache_root, "p")
	end
end

---@param key string
---@return string
local function key_to_hash(key)
	return vim.fn.sha256(key)
end

---@param hash string
---@param expires_at number|nil
---@return string
local function cache_path(hash, expires_at)
	local expires = tonumber(expires_at) or 0
	return string.format("%s/%s__%d.json", cache_root, hash, expires)
end

---@param hash string
---@return string[]
local function paths_for_hash(hash)
	return vim.fn.globpath(cache_root, string.format("%s__*.json", hash), false, true)
end

---@param path string
---@return number|nil
local function parse_expires_at(path)
	local filename = vim.fn.fnamemodify(path, ":t")
	local _, _, expires = filename:find("^[0-9a-f]+__(%d+)%.json$")
	if expires == nil then
		return nil
	end
	return tonumber(expires)
end

---@param key string
---@return string|nil
local function key_to_path(key)
	local hash = key_to_hash(key)
	local paths = paths_for_hash(hash)
	if not paths or #paths == 0 then
		return nil
	end

	table.sort(paths)
	return paths[#paths]
end

---@param key string
local function delete_paths_for_key(key)
	for _, path in ipairs(paths_for_hash(key_to_hash(key))) do
		pcall(vim.fn.delete, path)
	end
end

---@param path string
---@return CacheEntry|nil
local function read_entry(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end

	local lines = vim.fn.readfile(path)
	if not lines or #lines == 0 then
		return nil
	end

	local raw = table.concat(lines, "\n")
	local ok, decoded = pcall(vim.fn.json_decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

---@return string[]
local function cache_files()
	return vim.fn.globpath(cache_root, "*.json", false, true)
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set(key, value, ttl)
	ensure_cache_dir()
	M.prune_expired()

	local expires_at = nil
	if ttl ~= nil and ttl > 0 then
		expires_at = os.time() + ttl
	end

	local entry = {
		key = key,
		value = value,
		expires_at = expires_at,
	}

	local encoded = vim.json.encode(entry)
	delete_paths_for_key(key)
	vim.fn.writefile({ encoded }, cache_path(key_to_hash(key), expires_at))
end

---@param key string
---@return CacheEntry|nil
function M.get(key)
	ensure_cache_dir()
	M.prune_expired()

	local path = key_to_path(key)
	if path == nil then
		return nil
	end

	local entry = read_entry(path)
	if not entry then
		return nil
	end

	if entry.expires_at and os.time() > entry.expires_at then
		pcall(vim.fn.delete, path)
		return nil
	end

	return entry
end

---@param key string
function M.delete(key)
	delete_paths_for_key(key)
end

---@param prefix string
function M.clear_prefix(prefix)
	for _, path in ipairs(cache_files()) do
		local entry = read_entry(path)
		if entry and entry.key and entry.key:sub(1, #prefix) == prefix then
			pcall(vim.fn.delete, path)
		end
	end
end

function M.clear_all()
	if vim.fn.isdirectory(atlas_cache_root) == 1 then
		pcall(vim.fn.delete, atlas_cache_root, "rf")
	end
end

---@param opts? { remove_invalid?: boolean, force?: boolean }
---@return integer removed_count
function M.prune_expired(opts)
	opts = opts or {}
	ensure_cache_dir()

	local now = os.time()
	if not opts.force and last_prune_at > 0 and (now - last_prune_at) < PRUNE_INTERVAL_SEC then
		return 0
	end

	last_prune_at = now
	local removed = 0

	for _, path in ipairs(cache_files()) do
		local should_delete = false
		local expires_at = parse_expires_at(path)

		if expires_at == nil then
			should_delete = opts.remove_invalid == true
		elseif expires_at > 0 and now > expires_at then
			should_delete = true
		end

		if should_delete and pcall(vim.fn.delete, path) then
			removed = removed + 1
		end
	end

	return removed
end

return M
