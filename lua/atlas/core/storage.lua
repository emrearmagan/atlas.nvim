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
function M.pr_target(pr)
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

function M.prune()
	local dirs = vim.fn.globpath(M.root(), "**/", false, true)
	table.sort(dirs, function(left, right)
		return #left > #right
	end)
	for _, dir in ipairs(dirs) do
		vim.fn.delete(dir, "d")
	end
end

---@param path string
---@return table|nil, string|nil
function M.read(path)
	if vim.fn.filereadable(path) == 0 then
		return nil, nil
	end
	local ok, value = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if not ok or type(value) ~= "table" then
		return nil, "Unable to read " .. path
	end
	return value, nil
end

---@param path string
---@param value table
---@return string|nil
function M.write(path, value)
	local directory = vim.fs.dirname(path)
	local mkdir_ok, created = pcall(vim.fn.mkdir, directory, "p")
	if not mkdir_ok or (created == 0 and vim.fn.isdirectory(directory) == 0) then
		return "Unable to create " .. directory
	end
	local ok, encoded = pcall(vim.json.encode, value, { indent = "  " })
	if not ok then
		return "Unable to encode " .. path
	end
	local temp = path .. ".tmp." .. tostring(vim.uv.hrtime())
	local write_ok, result = pcall(vim.fn.writefile, vim.split(encoded, "\n", { plain = true }), temp)
	if not write_ok or result ~= 0 then
		vim.fn.delete(temp)
		return "Unable to write " .. path
	end
	local renamed, err = vim.uv.fs_rename(temp, path)
	if not renamed then
		vim.fn.delete(temp)
		return "Unable to save " .. path .. ": " .. tostring(err)
	end
	return nil
end

---@param path string
---@return string|nil
function M.delete(path)
	if vim.fn.filereadable(path) == 1 and vim.fn.delete(path) ~= 0 then
		return "Unable to delete " .. path
	end
	M.prune()
	return nil
end

return M
