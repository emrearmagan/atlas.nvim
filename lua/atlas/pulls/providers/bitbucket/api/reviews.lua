local M = {}

local comments = require("atlas.pulls.providers.bitbucket.api.comments")
local pullrequests = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local tasks = require("atlas.pulls.providers.bitbucket.api.tasks")

---@param pr PullRequest
---@param action "approve"|"request_changes"
---@return boolean
function M.has_action(pr, action)
	---@cast pr BitbucketPullRequest
	return tostring(pr.links[action] or "") ~= ""
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
---@return nil
function M.fetch_review_context(pr, _opts, on_done)
	local mention_candidates = {}
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
		table.insert(mention_candidates, author)
	end

	add(pr.author)
	on_done({ mention_candidates = mention_candidates }, nil)
end

---@param user table|nil
---@return PullsAuthor|nil
local function review_author(user)
	if not user then
		return nil
	end
	local username = tostring(user.nickname or user.username or "")
	local name = tostring(user.display_name or user.name or "")
	if username == "" and name == "" then
		return nil
	end
	return {
		id = tostring(user.account_id or user.uuid or user.id or ""),
		name = name ~= "" and name or username,
		username = username,
		nickname = username ~= "" and username or nil,
	}
end

---@param result table|nil
---@return PullsReviewHistoryEntry[]
local function review_history(result)
	local history = {}
	for _, item in ipairs((result or {}).values or {}) do
		local event = item.approval or item.changes_request
		if event then
			table.insert(history, {
				author = review_author(event.user),
				state = item.approval and "approved" or "changes_requested",
				submitted_on = tostring(event.date or ""),
			})
		end
	end
	table.sort(history, function(a, b)
		return a.submitted_on < b.submitted_on
	end)
	return history
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(history: PullsReviewHistoryEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_review_history(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local activity_url = tostring(pr.links.activity or "")
	if activity_url == "" then
		on_done({}, nil)
		return nil
	end

	local sep = activity_url:find("?") and "&" or "?"
	local fields = "values.approval,values.changes_request,next"
	local url = string.format("%s%spagelen=50&fields=%s", activity_url, sep, fields)
	local key = "bitbucket:pr:review-history:" .. url
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local history = review_history(result)
		service.set_cache(key, history)
		on_done(history, nil)
	end, { action = "Fetch PR review history", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_review(pr, opts, on_done)
	opts = opts or {}
	local requests = request_scope.new()
	requests.all({
		comments = function(done)
			return comments.fetch_comments(pr, opts, done)
		end,
		tasks = function(done)
			return tasks.fetch_tasks(pr, opts, done)
		end,
		reviewers = function(done)
			return pullrequests.fetch_reviewers(pr, opts, done)
		end,
		history = function(done)
			return fetch_review_history(pr, opts, done)
		end,
	}, function(values, errors)
		local err = errors.comments or errors.tasks or errors.reviewers or errors.history
		if err then
			on_done(nil, err)
			return
		end

		local filtered_comments = {}
		for _, comment in ipairs(values.comments) do
			if (comment.inline or comment.file) and comment.state ~= "DELETED" then
				table.insert(filtered_comments, comment)
			end
		end
		local has_pending = false
		for _, items in ipairs({ values.comments, values.tasks }) do
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
			comments = filtered_comments,
			tasks = values.tasks,
			reviewers = values.reviewers,
			history = values.history,
		}, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve(pr, _review, body, on_done)
	---@cast pr BitbucketPullRequest
	local url = tostring(pr.links.approve or "")
	if url == "" then
		on_done(false, "No approve URL available")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("POST", url, nil, nil, done, {
			action = "Approve pull request",
			repo = pr.repo_full_name,
			id = pr.id,
		})
	end, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		if vim.trim(body) == "" then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			return comments.add_comment(pr, body, nil, done)
		end, function(comment, comment_err)
			on_done(comment ~= nil, comment_err)
		end)
	end)
	return requests
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes(pr, _review, body, on_done)
	---@cast pr BitbucketPullRequest
	local url = tostring(pr.links.request_changes or "")
	if url == "" then
		on_done(false, "No request changes URL available")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("POST", url, nil, nil, done, {
			action = "Request PR changes",
			repo = pr.repo_full_name,
			id = pr.id,
		})
	end, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		if vim.trim(body) == "" then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			return comments.add_comment(pr, body, nil, done)
		end, function(comment, comment_err)
			on_done(comment ~= nil, comment_err)
		end)
	end)
	return requests
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param _body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return nil
function M.submit_review(pr, _review, _body, on_done)
	local url = tostring((pr.link or {}).html or "")
	if url == "" then
		on_done(false, "No pull request URL available")
		return nil
	end

	-- TODO: I could not figure out how to resolve the pending comments and submit via the API, so for now we just open the PR in the browser for the user to submit their review.
	vim.ui.open(url)
	on_done(true, nil)
	return nil
end

---@param pr PullRequest
---@param _review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.discard_review(pr, _review, on_done)
	local requests = request_scope.new()

	local function delete_next(items, index)
		local item = items[index]
		if not item then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			if item.is_task then
				return tasks.delete_task(item, done)
			end
			return comments.delete_comment(pr, item, done)
		end, function(_, err)
			if err then
				on_done(false, err)
				return
			end
			delete_next(items, index + 1)
		end)
	end

	requests.all({
		comments = function(done)
			return comments.fetch_comments(pr, { force_refresh = true }, done)
		end,
		tasks = function(done)
			return tasks.fetch_tasks(pr, { force_refresh = true }, done)
		end,
	}, function(values, errors)
		local err = errors.comments or errors.tasks
		if err then
			on_done(false, err)
			return
		end

		local items = {}
		for _, task in ipairs(values.tasks) do
			if task.state == "PENDING" then
				table.insert(items, task)
			end
		end
		for index = #values.comments, 1, -1 do
			if values.comments[index].state == "PENDING" then
				table.insert(items, values.comments[index])
			end
		end
		delete_next(items, 1)
	end)
	return requests
end

return M
