local service = require("atlas.providers.gitea.client").issues
local pagination = require("atlas.issues.providers.gitea.api.pagination")
local mapper = require("atlas.issues.providers.gitea.api.mapper")
local json = require("atlas.core.json")

local M = {}

---@param key string
---@return string|nil, integer|nil
local function endpoint(key)
	local slug, number = mapper.parse_key(key)
	local owner, repo = slug:match("^([^/]+)/([^/]+)$")
	if not owner or not number then
		return nil, nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo)), number
end

---@param key string
---@param comment_id string|integer
---@return string|nil
local function reactions_endpoint(key, comment_id)
	local base, number = endpoint(key)
	if not base then
		return nil
	end
	if tostring(comment_id) == "__body__" then
		return string.format("%s/issues/%d/reactions", base, number)
	end
	local id = tonumber(comment_id)
	if not id then
		return nil
	end
	return string.format("%s/issues/comments/%d/reactions", base, id)
end

---@param values table[]
---@return table<string, number>|nil
local function reaction_counts(values)
	local counts
	for _, raw in ipairs(json.nilify(values) or {}) do
		local content = raw.content
		if content ~= "" then
			counts = counts or {}
			counts[content] = (counts[content] or 0) + 1
		end
	end
	return counts
end

---@param key string
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
function M.add(key, body, on_done)
	local base, number = endpoint(key)
	if not base or vim.trim(body) == "" then
		on_done(nil, not base and "Invalid Gitea/Forgejo issue key" or "Comment cannot be empty")
		return nil
	end
	return service.request(
		"POST",
		string.format("%s/issues/%d/comments", base, number),
		{ body = body },
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(mapper.to_comment(raw), nil)
		end
	)
end

---@param key string
---@param comment_id string|integer
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
function M.edit(key, comment_id, body, on_done)
	local base = endpoint(key)
	if not base or tonumber(comment_id) == nil or vim.trim(body) == "" then
		on_done(nil, not base and "Invalid Gitea/Forgejo issue key" or "Invalid comment")
		return nil
	end
	return service.request(
		"PATCH",
		string.format("%s/issues/comments/%d", base, tonumber(comment_id)),
		{ body = body },
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(mapper.to_comment(raw), nil)
		end
	)
end

---@param key string
---@param comment_id string|integer
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete(key, comment_id, on_done)
	local base = endpoint(key)
	if not base or tonumber(comment_id) == nil then
		on_done(false, not base and "Invalid Gitea/Forgejo issue key" or "Invalid comment")
		return nil
	end
	return service.request(
		"DELETE",
		string.format("%s/issues/comments/%d", base, tonumber(comment_id)),
		nil,
		function(_, err)
			on_done(err == nil, err)
		end
	)
end

---@param key string
---@param comment_id string|integer
---@param on_done fun(reactions: table<string, number>|nil, err: string|nil)
function M.list_reactions(key, comment_id, on_done)
	local path = reactions_endpoint(key, comment_id)
	if not path then
		on_done(nil, "Invalid Gitea/Forgejo issue or comment")
		return nil
	end
	if tostring(comment_id) == "__body__" then
		return pagination.fetch_all(path, nil, {}, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(reaction_counts(raw), nil)
		end)
	end
	return service.request("GET", path, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(reaction_counts(raw), nil)
	end)
end

---@param key string
---@param comment_id string|integer
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
function M.add_reaction(key, comment_id, content, on_done)
	local path = reactions_endpoint(key, comment_id)
	content = vim.trim(content)
	if not path or content == "" then
		on_done(false, not path and "Invalid Gitea/Forgejo issue or comment" or "Reaction is required")
		return nil
	end
	return service.request("POST", path, { content = content }, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
