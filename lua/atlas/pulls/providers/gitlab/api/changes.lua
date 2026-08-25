local M = {}

local service = require("atlas.providers.gitlab.client")
local diff_parser = require("atlas.core.git.diff_parser")
local json = require("atlas.core.json")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:commits:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/commits?per_page=100", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local raw = json.safe_table(raw_value)
			local hash = tostring(raw.id or "")
			local short = tostring(raw.short_id or (hash ~= "" and hash:sub(1, 8) or ""))
			local title = tostring(raw.title or raw.message or "")
			table.insert(commits, {
				hash = hash,
				short_hash = short ~= "" and short or nil,
				message = title:match("([^\r\n]+)") or title,
				author_name = tostring(raw.author_name or ""),
				author_nickname = nil,
				date = tostring(raw.authored_date or raw.committed_date or ""),
				html_url = json.safe_str(raw.web_url),
			})
		end
		service.set_memory_cache(cache_key, commits)
		on_done(commits, nil)
	end, {
		action = "Fetch MR commits",
		project_path = path,
		iid = iid,
	})
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

	local cache_key = string.format("gitlab_pulls:diff:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/changes", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local parts = {}
		for _, change in ipairs(json.safe_table(json.safe_table(result).changes)) do
			table.insert(parts, rebuild_unified_diff(change))
		end
		local files = diff_parser.parse(table.concat(parts, "\n"))
		service.set_memory_cache(cache_key, files)
		on_done(files, nil)
	end, {
		action = "Fetch MR diff",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	return M.fetch_diff(pr, opts, function(files, err)
		if not files then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, file in ipairs(files) do
			local additions, deletions = file.additions, file.deletions
			if additions == nil and deletions == nil then
				additions, deletions = 0, 0
				for _, hunk in ipairs(file.hunks) do
					additions = additions + hunk.additions
					deletions = deletions + hunk.deletions
				end
			end
			table.insert(entries, {
				status = file.status,
				path = file.path,
				old_path = file.old_path,
				lines_added = additions or 0,
				lines_removed = deletions or 0,
			})
		end
		on_done(entries, nil)
	end)
end

return M
