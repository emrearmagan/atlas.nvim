local service = require("atlas.providers.gitea.gitea.client").pulls
local pagination = require("atlas.pulls.providers.gitea.gitea.api.pagination")

local M = {}

---@param pr PullRequest
---@return string|nil
local function diffstat_cache_key(pr)
	local source = type(pr.source) == "table" and pr.source or {}
	local destination = type(pr.destination) == "table" and pr.destination or {}
	local head = tostring(source.commit_hash or "")
	local base = tostring(destination.commit_hash or "")
	if head == "" or base == "" then
		return nil
	end
	return table.concat({
		"gitea:pulls:gitea:diffstat",
		service.url_encode(service.base_url()),
		service.url_encode(tostring(pr.repo_full_name or "")),
		tostring(pr.id or ""),
		service.url_encode(head),
		service.url_encode(base),
	}, ":")
end

local function endpoint(pr)
	if type(pr) ~= "table" then
		return nil
	end
	local owner, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	local id = tostring(pr.id or "")
	if owner and id:match("^%d+$") then
		return string.format("/repos/%s/%s/pulls/%s", service.url_encode(owner), service.url_encode(repo), id)
	end
end

function M.diffstat(pr, opts, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	opts = opts or {}
	local key = diffstat_cache_key(pr)
	if key and opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return pagination.fetch_all(base .. "/files", nil, {
		invalid_response = "Invalid pull request files response",
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, file in ipairs(raw or {}) do
			if type(file) ~= "table" or file.filename == nil or file.filename == "" then
				on_done(nil, "Invalid pull request files response")
				return
			end
			local status = tostring(file.status or "modified"):lower()
			table.insert(entries, {
				status = status == "changed" and "modified" or (status == "deleted" and "removed" or status),
				path = file.filename,
				old_path = file.previous_filename,
				lines_added = file.additions or 0,
				lines_removed = file.deletions or 0,
			})
		end
		if key then
			service.set_memory_cache(key, entries)
		end
		on_done(entries, nil)
	end)
end

function M.diff(pr, _, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return service.request_text("GET", base .. ".diff", function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(require("atlas.core.git.diff_parser").parse(tostring(raw or "")), nil)
	end)
end

return M
