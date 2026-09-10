local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")
local mapper = require("atlas.pulls.providers.azure.api.mapper")
local changes_api = require("atlas.pulls.providers.azure.api.changes")

---@param pr PullRequest
---@return string
local function pullrequest_endpoint(pr)
	return string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
		tostring(pr.id)
	)
end

---@param pr PullRequest
---@param comment PullsComment
---@return string
local function comment_endpoint(pr, comment)
	return string.format(
		"%s/threads/%s/comments/%s",
		pullrequest_endpoint(pr),
		comment.thread_id,
		tostring(comment.id):match(":(%d+)$")
	)
end

---@param pr PullRequest
---@param path string
---@param commit_hash string
---@param on_done fun(context: table|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_thread_context(pr, path, commit_hash, on_done)
	local endpoint = pullrequest_endpoint(pr)
	local scope = request_scope.new()
	local context = { action = "Fetch comment position", repo = pr.repo_full_name, id = pr.id }
	scope.run(function(done)
		return changes_api.fetch_iteration(pr, commit_hash, done)
	end, function(iteration, err)
		if err then
			on_done(nil, err)
			return
		end
		local function fetch_page(skip)
			local query = service.build_query({ ["$compareTo"] = 0, ["$top"] = 100, ["$skip"] = skip })
			local changes_endpoint = endpoint .. "/iterations/" .. iteration .. "/changes" .. query
			scope.run(function(done)
				return service.request("GET", changes_endpoint, nil, done, context)
			end, function(changes, changes_err)
				if changes_err then
					on_done(nil, changes_err)
					return
				end
				for _, change in ipairs(changes.changeEntries) do
					if change.item.path == "/" .. path or change.originalPath == "/" .. path then
						on_done({
							changeTrackingId = change.changeTrackingId,
							iterationContext = {
								firstComparingIteration = iteration,
								secondComparingIteration = iteration,
							},
						}, nil)
						return
					end
				end
				if (changes.nextSkip or 0) > 0 then
					fetch_page(changes.nextSkip)
					return
				end
				on_done(nil, "File is not part of the pull request: " .. path)
			end)
		end
		fetch_page(0)
	end)
	return scope
end

---@param pr PullRequest
---@param body table
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function create_thread(pr, body, on_done)
	return service.request("POST", pullrequest_endpoint(pr) .. "/threads", body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		on_done(mapper.to_comment(result.comments[1], result, pr), nil)
	end, { action = "Add pull request comment", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}
	if opts.pending then
		on_done(nil, "Azure DevOps does not support pending review comments")
		return nil
	end
	local parent = opts.parent
	if parent then
		local body = {
			content = content,
			parentCommentId = tonumber(tostring(parent.parent_id or parent.id):match(":(%d+)$")),
			commentType = "text",
		}
		local endpoint = pullrequest_endpoint(pr) .. "/threads/" .. parent.thread_id .. "/comments"
		return service.request("POST", endpoint, body, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			service.clear_cache()
			local comment = mapper.to_comment(result, { id = parent.thread_id }, pr)
			comment.inline = parent.inline
			comment.file = parent.file
			comment.state = parent.state
			comment.outdated = parent.outdated
			on_done(comment, nil)
		end, { action = "Reply to pull request comment", repo = pr.repo_full_name, id = pr.id })
	end

	local body = {
		comments = { { content = content, parentCommentId = 0, commentType = "text" } },
		status = "active",
	}
	local position = opts.inline or opts.file
	if not position then
		return create_thread(pr, body, on_done)
	end
	local inline = opts.inline
	body.threadContext = {
		filePath = "/" .. position.path,
		leftFileStart = inline and inline.from and { line = inline.start_from or inline.from, offset = 1 } or nil,
		leftFileEnd = inline and inline.from and { line = inline.from, offset = inline.from_offset or 1 } or nil,
		rightFileStart = inline and inline.to and { line = inline.start_to or inline.to, offset = 1 } or nil,
		rightFileEnd = inline and inline.to and { line = inline.to, offset = inline.to_offset or 1 } or nil,
	}
	local scope = request_scope.new()
	scope.run(function(done)
		return fetch_thread_context(pr, position.path, position.commit_hash or pr.source.commit_hash, done)
	end, function(context, err)
		if err then
			on_done(nil, err)
			return
		end
		body.pullRequestThreadContext = context
		scope.run(function(done)
			return create_thread(pr, body, done)
		end, on_done)
	end)
	return scope
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	local body = { content = comment.content_raw }
	return service.request("PATCH", comment_endpoint(pr, comment), body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		local updated = mapper.to_comment(result, { id = comment.thread_id }, pr)
		on_done(vim.tbl_extend("force", {}, comment, updated), nil)
	end, { action = "Edit pull request comment", repo = pr.repo_full_name, id = pr.id, comment_id = comment.id })
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment, on_done)
	return service.request("DELETE", comment_endpoint(pr, comment), nil, function(_, err)
		if not err then
			service.clear_cache()
		end
		on_done(err == nil, err)
	end, { action = "Delete pull request comment", repo = pr.repo_full_name, id = pr.id, comment_id = comment.id })
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param _key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(pr, item, _key, on_done)
	if item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	---@type PullsComment
	local comment = item.entity
	return service.request("POST", comment_endpoint(pr, comment) .. "/likes", nil, function(_, err)
		if not err then
			service.clear_cache()
		end
		on_done(err == nil, err)
	end, { action = "Like pull request comment", repo = pr.repo_full_name, id = pr.id, comment_id = comment.id })
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local endpoint = pullrequest_endpoint(pr) .. "/threads/" .. root.thread_id
	return service.request("PATCH", endpoint, { status = resolved and "fixed" or "active" }, function(_, err)
		if not err then
			service.clear_cache()
		end
		on_done(err == nil, err)
	end, {
		action = resolved and "Resolve pull request thread" or "Reopen pull request thread",
		repo = pr.repo_full_name,
		id = pr.id,
		thread_id = root.thread_id,
	})
end

return M
