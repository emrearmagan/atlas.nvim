local mapper = require("atlas.issues.providers.forgejo.api.mapper")

local M = {}
local service = require("atlas.providers.forgejo.client")

---@param issue ForgejoIssue
---@return string|nil, integer|nil
local function endpoint(issue)
	local owner, repo = issue.repo_full_name:match("^([^/]+)/([^/]+)$")
	local number = issue.number
	if not owner or not number then
		return nil, nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo)), number
end

---@param issue ForgejoIssue
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
function M.add(issue, body, on_done)
	local base, number = endpoint(issue)
	if not base or vim.trim(body) == "" then
		on_done(nil, not base and "Invalid Forgejo issue key" or "Comment cannot be empty")
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

---@param issue ForgejoIssue
---@param comment_id string|integer
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
function M.edit(issue, comment_id, body, on_done)
	local base = endpoint(issue)
	if not base or tonumber(comment_id) == nil or vim.trim(body) == "" then
		on_done(nil, not base and "Invalid Forgejo issue key" or "Invalid comment")
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

---@param issue ForgejoIssue
---@param comment_id string|integer
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete(issue, comment_id, on_done)
	local base = endpoint(issue)
	if not base or tonumber(comment_id) == nil then
		on_done(false, not base and "Invalid Forgejo issue key" or "Invalid comment")
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

---@param issue ForgejoIssue
---@param comment_id string|integer
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
function M.add_reaction(issue, comment_id, content, on_done)
	local base = endpoint(issue)
	local id = tonumber(comment_id)
	content = vim.trim(content)
	if not base or not id or content == "" then
		on_done(false, (not base or not id) and "Invalid Forgejo issue or comment" or "Reaction is required")
		return nil
	end
	return service.request(
		"POST",
		string.format("%s/issues/comments/%d/reactions", base, id),
		{ content = content },
		function(_, err)
			on_done(err == nil, err)
		end
	)
end

return M
