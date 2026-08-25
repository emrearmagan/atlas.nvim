local service = require("atlas.providers.gitea.client")
local pagination = require("atlas.providers.gitea.pagination")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

local M = {}

---@param issue GiteaIssue
---@param _ table|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(issue, _, on_done)
	local owner, repo = issue.repo_full_name:match("^([^/]+)/([^/]+)$")
	local number = issue.number
	if not owner or not number then
		on_done(nil, "Invalid Gitea issue key")
		return nil
	end
	local path =
		string.format("/repos/%s/%s/issues/%d/timeline", service.url_encode(owner), service.url_encode(repo), number)

	return pagination.fetch_all(path, nil, nil, function(values, err)
		if err then
			on_done(nil, err)
			return
		end

		local result = { comments = {}, events = {} }
		for _, raw in ipairs(values) do
			local raw_type = raw.type
			if raw_type == "comment" then
				table.insert(result.comments, mapper.to_comment(raw))
			else
				table.insert(result.events, mapper.to_timeline_entry(raw))
			end
		end
		on_done(result, nil)
	end)
end

return M
