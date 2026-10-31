local M = {}
local providers = require("atlas.providers")
local storage = require("atlas.core.storage")

local path = vim.fs.joinpath(storage.root(), "starred-v4.json")

---@class AtlasStarredItem
---@field ref string
---@field domain "pulls"|"issues"
---@field provider string
---@field hostname string|nil
---@field item PullRequestRef|IssueRef

---@param value PullRequestRef|IssueRef
---@param provider string
---@return AtlasStarredItem
local function to_item(value, provider)
	local domain = value.key and "issues" or "pulls"
	local id = value.key or (value.repo_full_name .. "#" .. tostring(value.id))
	local hostname = providers[provider].hostname()
	local namespace = hostname and (provider .. ":" .. hostname) or provider

	return {
		ref = string.format("%s:%s/%s", namespace, domain, id),
		domain = domain,
		provider = provider,
		hostname = hostname,
		item = domain == "issues" and { key = value.key } or { id = value.id, repo_full_name = value.repo_full_name },
	}
end

---@param value PullRequestRef|IssueRef
---@param provider string
---@return string
function M.ref(value, provider)
	return to_item(value, provider).ref
end

---@param values table<string, AtlasStarredItem>
---@return string|nil
local function write(values)
	if next(values) == nil then
		return storage.delete(path)
	end
	return storage.write(path, values)
end

---@return table<string, AtlasStarredItem>|nil, string|nil
local function load()
	local value, err = storage.read(path)
	if err then
		return nil, err
	end
	if not value then
		return {}, nil
	end

	for ref, item in pairs(value) do
		if type(item) ~= "table" then
			return nil, "Unable to read " .. path
		end
		item.ref = tostring(ref)
	end
	return value, nil
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
			if item.hostname == providers[item.provider].hostname() then
				table.insert(result, item)
			end
		end
	end
	table.sort(result, function(a, b)
		return a.ref < b.ref
	end)
	return result, nil
end

---@param value PullRequestRef|IssueRef
---@param provider string
---@return AtlasStarredItem|nil, string|nil
function M.add(value, provider)
	local item = to_item(value, provider)
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

---@param value PullRequestRef|IssueRef
---@param provider string
---@return boolean|nil, string|nil
function M.toggle(value, provider)
	local item = to_item(value, provider)
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
	-- TODO: Drop this at some point. It only cleans up the old starred versions.
	for _, name in ipairs({ "starred.json", "starred-v2.json", "starred-v3.json" }) do
		vim.fn.delete(vim.fs.joinpath(storage.root(), name))
	end
	local err = storage.delete(path)
	return err == nil, err
end

return M
