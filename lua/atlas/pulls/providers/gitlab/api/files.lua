local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
end

---@param change table
---@return string
local function rebuild_unified_diff(change)
	local new_path = tostring(change.new_path or "")
	local old_path = tostring(change.old_path or new_path)
	local body = tostring(change.diff or "")
	local header = string.format("diff --git a/%s b/%s\n", old_path, new_path)
	if change.new_file == true then
		header = header .. "new file\n"
	elseif change.deleted_file == true then
		header = header .. "deleted file\n"
	end
	if not body:find("^%-%-%- ") then
		header = header .. string.format("--- a/%s\n+++ b/%s\n", old_path, new_path)
	end
	return header .. body
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/changes", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local parts = {}
		for _, change in ipairs(type(result.changes) == "table" and result.changes or {}) do
			if type(change) == "table" then
				table.insert(parts, rebuild_unified_diff(change))
			end
		end
		local diff_parser = require("atlas.core.git.diff_parser")
		on_done(diff_parser.parse(table.concat(parts, "\n")), nil)
	end)
end

return M
