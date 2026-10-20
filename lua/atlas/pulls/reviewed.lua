-- Remembers the files you marked reviewed, for providers that can't save that themselves (GitLab, Bitbucket).
-- Saved per pull request in reviewed.json as { [path] = "old_blob:new_blob" }. A mark only counts until
-- the file changes again.

local notify = require("atlas.core.notify")
local storage = require("atlas.core.storage")

local M = {}

---@param pr PullRequest
---@return string|nil, string|nil
local function path(pr)
	local target, err = storage.pr_target(pr)
	if not target then
		return nil, err
	end
	return vim.fs.joinpath(storage.dir(target), "reviewed.json"), nil
end

---@param file AtlasDiffFile
---@return string
local function fingerprint(file)
	return (file.old_blob or "") .. ":" .. (file.new_blob or "")
end

---@param pr PullRequest
---@return table<string, string>|nil, string|nil
function M.read(pr)
	local file_path, err = path(pr)
	if not file_path then
		return nil, err
	end
	local marks, read_err = storage.read(file_path)
	if read_err then
		return nil, read_err
	end
	return marks or {}, nil
end

---@param marks table<string, string>
---@param files AtlasDiffFile[]
---@return PullsReviewContext
function M.review_context(marks, files)
	local reviewed_files = {}
	for _, file in ipairs(files) do
		if marks[file.path] == fingerprint(file) then
			reviewed_files[file.path] = true
		end
	end
	return { reviewed_files = reviewed_files }
end

---@param pr PullRequest
---@param files AtlasDiffFile[]
---@param reviewed boolean
---@return string|nil
function M.set(pr, files, reviewed)
	local file_path, err = path(pr)
	if not file_path then
		return err
	end
	local marks, read_err = storage.read(file_path)
	if read_err then
		return read_err
	end
	marks = marks or {}
	for _, file in ipairs(files) do
		marks[file.path] = reviewed and fingerprint(file) or nil
	end
	if next(marks) == nil then
		return storage.delete(file_path)
	end
	return storage.write(file_path, marks)
end

---@param pr PullRequest
function M.clear(pr)
	local file_path, err = path(pr)
	if file_path then
		err = storage.delete(file_path)
	end
	if err then
		notify.warn(err, { vim_notify = true })
	end
end

---@return boolean, string|nil
function M.clear_all()
	for _, file_path in ipairs(vim.fn.globpath(storage.root(), "**/pr-*/reviewed.json", false, true)) do
		local err = storage.delete(file_path)
		if err then
			return false, err
		end
	end
	return true, nil
end

return M
