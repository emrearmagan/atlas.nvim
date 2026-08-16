local service = require("atlas.providers.gitea.client").issues
local json = require("atlas.core.json")
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
		on_done(nil, "Invalid Gitea/Forgejo issue key")
		return nil
	end

	return pagination.fetch_all(path, nil, {
		invalid_response = "Invalid Gitea/Forgejo timeline response",
		post_filtered = true,
	}, function(values, err)
		if err then
			on_done(nil, err)
			return
		end

		local result = { comments = {}, events = {} }
		for _, raw in ipairs(values or {}) do
			local raw_type = type(raw) == "table" and json.safe_str(raw.type) or nil
			if raw_type == "comment" then
				local comment = mapper.to_comment(raw)
				if comment then
					table.insert(result.comments, comment)
				end
			else
				local entry = mapper.to_timeline_entry(raw)
				if entry then
					table.insert(result.events, entry)
				end
			end
		end
		on_done(result, nil)
	end)
end

return M
