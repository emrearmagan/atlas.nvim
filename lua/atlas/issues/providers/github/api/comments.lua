local M = {}

local cache = require("atlas.issues.providers.github.api.cache")
local cli = require("atlas.providers.github.client")
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param issue Issue
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(issue, body, on_done)
	---@cast issue GitHubIssue
	local slug = issue.repo_full_name
	local number = issue.number
	if slug == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.api(
		"POST",
		string.format("repos/%s/issues/%d/comments", slug, number),
		{ body = body },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Empty response")
				return
			end
			cache.invalidate(issue.key)
			on_done(normalizer.to_comment(result), nil)
		end,
		{
			action = "Add issue comment",
			slug = slug,
			number = number,
		}
	)
end

---@param issue Issue
---@param comment IssueComment
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit(issue, comment, body, on_done)
	---@cast issue GitHubIssue
	local slug = issue.repo_full_name
	if slug == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.api(
		"PATCH",
		string.format("repos/%s/issues/comments/%s", slug, tostring(comment.id)),
		{ body = body },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Empty response")
				return
			end
			cache.invalidate(issue.key)
			on_done(normalizer.to_comment(result), nil)
		end,
		{
			action = "Edit issue comment",
			slug = slug,
			comment_id = comment.id,
		}
	)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(issue, comment, on_done)
	---@cast issue GitHubIssue
	local slug = issue.repo_full_name
	if slug == "" then
		on_done(false, "Invalid issue key")
		return nil
	end

	return cli.api(
		"DELETE",
		string.format("repos/%s/issues/comments/%s", slug, tostring(comment.id)),
		nil,
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			cache.invalidate(issue.key)
			on_done(true, nil)
		end,
		{
			action = "Delete issue comment",
			slug = slug,
			comment_id = comment.id,
		}
	)
end

return M
