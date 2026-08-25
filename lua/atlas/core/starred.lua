local M = {}

local path = vim.fs.joinpath(vim.fn.stdpath("data"), "atlas", "starred-v2.json")

---@class AtlasStarredItem
---@field ref string
---@field domain "pulls"|"issues"
---@field provider string
---@field item PullRequest|Issue
---@field repo PullsRepo|nil

---@param value PullRequest|Issue
---@param provider string
---@param repo PullsRepo|nil
---@return AtlasStarredItem
local function to_item(value, provider, repo)
	local domain = value.key and "issues" or "pulls"
	local id = value.key or (value.repo_full_name .. "#" .. tostring(value.id))

	return {
		ref = string.format("%s:%s/%s", provider, domain, id),
		domain = domain,
		provider = provider,
		item = value,
		repo = repo,
	}
end

---@param value PullRequest|Issue
---@param provider string
---@return string
function M.ref(value, provider)
	return to_item(value, provider).ref
end

---@return table<string, AtlasStarredItem>|nil, string|nil
local function load()
	if vim.fn.filereadable(path) == 0 then
		return {}, nil
	end
	local ok, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(value) ~= "table" then
		return nil, "Unable to read starred items: " .. path
	end
	for ref, item in pairs(value) do
		if type(item) ~= "table" then
			return nil, "Unable to read starred items: " .. path
		end
		item.ref = tostring(ref)
	end
	return value, nil
end

---@param values table<string, AtlasStarredItem>
---@return string|nil
local function write(values)
	if next(values) == nil then
		if vim.fn.filereadable(path) == 1 and vim.fn.delete(path) ~= 0 then
			return "Unable to delete starred items: " .. path
		end
		return nil
	end

	local directory = vim.fs.dirname(path)
	if vim.fn.mkdir(directory, "p") == 0 and vim.fn.isdirectory(directory) == 0 then
		return "Unable to create Atlas data directory"
	end

	local ok, encoded = pcall(vim.json.encode, values)
	if not ok then
		return "Unable to encode starred items"
	end
	local temp = path .. ".tmp." .. tostring(vim.uv.hrtime())
	if vim.fn.writefile({ encoded }, temp) ~= 0 then
		return "Unable to write starred items"
	end
	local renamed, err = vim.uv.fs_rename(temp, path)
	if not renamed then
		vim.fn.delete(temp)
		return "Unable to save starred items: " .. tostring(err)
	end
	return nil
end

---@param domain "pulls"|"issues"|nil
---@param provider string|nil
---@return AtlasStarredItem[]|nil, string|nil
function M.list(domain, provider)
	local items, err = load()
	if items == nil then
		return nil, err
	end
	local result = {}
	for _, item in pairs(items) do
		if (domain == nil or item.domain == domain) and (provider == nil or item.provider == provider) then
			table.insert(result, item)
		end
	end
	table.sort(result, function(a, b)
		return a.ref < b.ref
	end)
	return result, nil
end

---@param value PullRequest|Issue
---@param provider string
---@param repo PullsRepo|nil
---@return AtlasStarredItem|nil, string|nil
function M.add(value, provider, repo)
	local item = to_item(value, provider, repo)
	local items, err = load()
	if items == nil then
		return nil, err
	end
	items[item.ref] = item
	err = write(items)
	if err then
		return nil, err
	end
	return item, nil
end

---@param value PullRequest|Issue
---@param provider string
---@param repo PullsRepo|nil
---@return boolean|nil, string|nil
function M.toggle(value, provider, repo)
	local item = to_item(value, provider, repo)
	local items, err = load()
	if items == nil then
		return nil, err
	end
	local now_starred = items[item.ref] == nil
	items[item.ref] = now_starred and item or nil
	err = write(items)
	if err then
		return nil, err
	end
	return now_starred, nil
end

---@return boolean, string|nil
function M.clear_all()
	if vim.fn.filereadable(path) == 0 or vim.fn.delete(path) == 0 then
		return true, nil
	end
	return false, "Unable to delete starred items: " .. path
end

return M
