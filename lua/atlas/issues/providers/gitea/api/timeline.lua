local service = require("atlas.providers.gitea.client").issues
local pagination = require("atlas.issues.providers.gitea.api.pagination")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

local M = {}

---@param key string
---@return string|nil
local function endpoint(key)
	local slug, number = mapper.parse_key(key)
	local owner, repo = slug:match("^([^/]+)/([^/]+)$")
	if not owner or not number then
		return nil
	end
	return string.format("/repos/%s/%s/issues/%d/timeline", service.url_encode(owner), service.url_encode(repo), number)
end

---@param key string
---@param _ table|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(key, _, on_done)
	local path = endpoint(key)
	if path == nil then
		on_done(nil, "Invalid Gitea issue key")
		return nil
	end

	return pagination.fetch_all(path, nil, {
		post_filtered = true,
	}, function(values, err)
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
