local service = require("atlas.providers.gitea.forgejo.client").pulls
local pagination = require("atlas.pulls.providers.gitea.forgejo.api.pagination")

local M = {}

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

function M.diffstat(pr, _, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
		return nil
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
		on_done(entries, nil)
	end)
end

function M.diff(pr, _, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
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
