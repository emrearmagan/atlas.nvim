local M = {}

---@class AtlasStorageTarget
---@field ref string
---@field host string
---@field repository string
---@field id string

---@param value any
---@return string
local function text(value)
	return vim.trim(tostring(value or ""))
end

---@return string
function M.root()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "atlas")
end

---@param value { host: string, repository: string, id: string|integer }
---@return AtlasStorageTarget|nil, string|nil
function M.target(value)
	if type(value) ~= "table" then
		return nil, "A pull request target is required"
	end

	local host = text(value.host):lower()
	local repository = text(value.repository):lower()
	local id = text(value.id)
	if host == "" or repository == "" or not id:match("^%d+$") then
		return nil, "Invalid pull request target"
	end

	if host:find("/", 1, true) or repository:find("..", 1, true) then
		return nil, "Invalid pull request target"
	end

	return {
		ref = string.format("%s/%s/pr-%s", host, repository, id),
		host = host,
		repository = repository,
		id = id,
	},
		nil
end

---@param ref string
---@return AtlasStorageTarget|nil, string|nil
function M.parse(ref)
	local host, repository, id = text(ref):match("^([^/]+)/(.+)/pr%-(%d+)$")
	if not host then
		return nil, "Invalid pull request target"
	end
	return M.target({ host = host, repository = repository, id = id })
end

---@param pr PullRequest
---@return AtlasStorageTarget|nil, string|nil
function M.target_for_pull_request(pr)
	return M.target({
		host = pr.link.html:match("^https?://([^/?#]+)"),
		repository = pr.repo_full_name,
		id = pr.id,
	})
end

---@param target AtlasStorageTarget
---@return string
function M.dir(target)
	return vim.fs.joinpath(M.root(), target.ref)
end

return M
