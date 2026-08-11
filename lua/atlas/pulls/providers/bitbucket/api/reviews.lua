local M = {}

local changes = require("atlas.pulls.providers.bitbucket.api.changes")
local comments = require("atlas.pulls.providers.bitbucket.api.comments")
local diff_parser = require("atlas.core.git.diff_parser")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local tasks = require("atlas.pulls.providers.bitbucket.api.tasks")

---@param link any
---@return string
local function link_href(link)
	if type(link) == "string" then
		return link
	end
	if type(link) == "table" then
		return tostring(link.href or "")
	end
	return ""
end

---@param pr PullRequest
---@param key "approve"|"request_changes"
---@return string
local function action_url(pr, key)
	local links = type(pr._raw.links) == "table" and pr._raw.links or {}
	local link = links[key]
	if link == nil and key == "request_changes" then
		link = links["request-changes"]
	end
	return link_href(link)
end

---@param pr PullRequest
---@param action "approve"|"request_changes"
---@return boolean
function M.has_action(pr, action)
	return action_url(pr, action) ~= ""
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: { authors: PullsAuthor[] }|nil, err: string|nil)
---@return nil
function M.fetch_review_context(pr, _opts, on_done)
	local authors = {}
	local seen = {}
	---@param author PullsAuthor|nil
	local function add(author)
		if not author then
			return
		end
		local key = tostring(author.id or "")
		if key == "" then
			key = tostring(author.username or author.nickname or author.name or "")
		end
		if key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(authors, author)
	end

	add(pr.author)
	for _, participant in ipairs(pr._raw.participants or {}) do
		local user = type(participant) == "table" and participant.user or nil
		if type(user) == "table" then
			local id = tostring(user.account_id or user.id or "")
			local username = tostring(user.nickname or user.username or "")
			local name = tostring(user.display_name or user.name or username)
			if id ~= "" or username ~= "" or name ~= "" then
				add({
					id = id,
					name = name,
					username = username,
					nickname = username ~= "" and username or nil,
				})
			end
		end
	end
	on_done({ authors = authors }, nil)
end

---@param comment PullsComment
---@param files DiffFile[]
local function attach_hunk(comment, files)
	if not comment.inline then
		return
	end
	local side = comment.inline.to ~= nil and "new" or "old"
	local line = comment.inline.to or comment.inline.from
	if not line then
		return
	end
	for _, file in ipairs(files) do
		if file.path == comment.inline.path or file.old_path == comment.inline.path then
			comment.inline_hunk = diff_parser.find_hunk(file, side, line)
			if comment.inline_hunk then
				return
			end
		end
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_review(pr, opts, on_done)
	opts = opts or {}
	local review_comments, files, review_tasks
	local first_err
	local pending = 3
	local handles = {}
	local cancelled = false

	local function finish()
		pending = pending - 1
		if cancelled or pending > 0 then
			return
		end
		if first_err then
			on_done(nil, first_err)
			return
		end

		local inline_comments = {}
		for _, comment in ipairs(review_comments) do
			if comment.inline then
				attach_hunk(comment, files)
				table.insert(inline_comments, comment)
			end
		end
		local has_pending = false
		for _, items in ipairs({ review_comments, review_tasks }) do
			for _, item in ipairs(items) do
				-- Bitbucket only exposes pending items to their author.
				if item.state == "PENDING" then
					has_pending = true
					break
				end
			end
		end
		on_done({
			review = { id = nil, commit_hash = nil, pending = has_pending },
			comments = inline_comments,
			tasks = review_tasks,
		}, nil)
	end

	local function track(handle)
		if handle then
			table.insert(handles, handle)
		end
	end

	track(comments.fetch_comments(pr, opts, function(result, err)
		first_err = first_err or err
		review_comments = result or {}
		finish()
	end))
	track(changes.fetch_diff(pr, opts, function(result)
		files = result or {}
		finish()
	end))
	track(tasks.fetch_tasks(pr, opts, function(result, err)
		first_err = first_err or err
		review_tasks = result or {}
		finish()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve(pr, on_done)
	local url = action_url(pr, "approve")
	if url == "" then
		on_done(nil, "No approve URL available")
		return nil
	end
	return service.request("POST", url, nil, nil, on_done)
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.unapprove(pr, on_done)
	local url = action_url(pr, "approve")
	if url == "" then
		on_done(nil, "No approve URL available")
		return nil
	end
	return service.request("DELETE", url, nil, nil, on_done)
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes(pr, on_done)
	local url = action_url(pr, "request_changes")
	if url == "" then
		on_done(nil, "No request changes URL available")
		return nil
	end
	return service.request("POST", url, nil, nil, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit_review(pr, _review, body, on_done)
	-- TODO: How to resolve those pending comments?
	if vim.trim(body) == "" then
		on_done(false, "Review comment cannot be empty")
		return nil
	end

	return comments.add_comment(pr, body, nil, function(comment, err)
		if err or not comment then
			on_done(false, err or "Bitbucket did not return the review comment")
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param body string
---@param action fun(pr: PullRequest, on_done: fun(result: table|nil, err: string|nil)): { cancel: fun() }|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function complete(pr, body, action, on_done)
	local cancelled = false
	local current
	current = action(pr, function(_, err)
		if cancelled then
			return
		end
		if err or vim.trim(body) == "" then
			on_done(err == nil, err)
			return
		end
		current = M.submit_review(pr, nil, body, on_done)
	end)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve_review(pr, _review, body, on_done)
	return complete(pr, body, M.approve, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.request_changes_review(pr, _review, body, on_done)
	return complete(pr, body, M.request_changes, on_done)
end

---@param pr PullRequest
---@param _review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.discard_review(pr, _review, on_done)
	local review_comments, review_tasks
	local pending = 2
	local first_err
	local handles = {}
	local current
	local cancelled = false

	local function delete_next(items, index)
		if cancelled then
			return
		end
		local item = items[index]
		if not item then
			on_done(true, nil)
			return
		end
		local callback = function(_, err)
			if err then
				on_done(false, err)
				return
			end
			delete_next(items, index + 1)
		end
		if item.is_task then
			current = tasks.delete_task(item, callback)
		else
			current = comments.delete_comment(pr, item, callback)
		end
	end

	local function finish()
		pending = pending - 1
		if cancelled or pending > 0 then
			return
		end
		if first_err then
			on_done(false, first_err)
			return
		end

		local items = {}
		for _, task in ipairs(review_tasks) do
			if task.state == "PENDING" then
				table.insert(items, task)
			end
		end
		for index = #review_comments, 1, -1 do
			if review_comments[index].state == "PENDING" then
				table.insert(items, review_comments[index])
			end
		end
		delete_next(items, 1)
	end

	local function track(handle)
		if handle then
			table.insert(handles, handle)
		end
	end
	track(comments.fetch_comments(pr, { force_refresh = true }, function(result, err)
		first_err = first_err or err
		review_comments = result or {}
		finish()
	end))
	track(tasks.fetch_tasks(pr, { force_refresh = true }, function(result, err)
		first_err = first_err or err
		review_tasks = result or {}
		finish()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.cancel()
			end
			if current then
				current.cancel()
			end
		end,
	}
end

return M
