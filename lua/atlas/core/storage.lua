local M = {}

---@class AtlasStorageTarget
---@field ref string
---@field provider string
---@field host string
---@field repository string
---@field id string
---@field url string|nil

---@param value any
---@return string
local function text(value)
	return vim.trim(tostring(value or ""))
end

---@return string
function M.root()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "atlas")
end

---@param value { provider: string, host: string, repository: string, id: string|integer, url: string|nil }
---@return AtlasStorageTarget|nil, string|nil
function M.target(value)
	if type(value) ~= "table" then
		return nil, "A pull request target is required"
	end

	local provider = text(value.provider):lower()
	local host = text(value.host):lower()
	local repository = text(value.repository):lower()
	local id = text(value.id)
	if provider == "" or host == "" or repository == "" or not id:match("^%d+$") then
		return nil, "Invalid pull request target"
	end

	if host:find("/", 1, true) or repository:find("..", 1, true) then
		return nil, "Invalid pull request target"
	end

	local url = text(value.url)
	return {
		ref = string.format("%s/%s/pr-%s", host, repository, id),
		provider = provider,
		host = host,
		repository = repository,
		id = id,
		url = url ~= "" and url or nil,
	},
		nil
end

---@param pr PullRequest
---@return AtlasStorageTarget|nil, string|nil
function M.target_for_pull_request(pr)
	local url = pr.link.html

	return M.target({
		provider = pr.provider,
		host = url:match("^https?://([^/?#]+)"),
		repository = pr.repo_full_name,
		id = pr.id,
		url = url,
	})
end

---@param target AtlasStorageTarget
---@return string
function M.dir(target)
	return vim.fs.joinpath(M.root(), target.ref)
end

return M
