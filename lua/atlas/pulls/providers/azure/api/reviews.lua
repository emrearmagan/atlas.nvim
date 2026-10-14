local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.azure.client")
local mapper = require("atlas.pulls.providers.azure.api.mapper")
local changes = require("atlas.pulls.providers.azure.api.changes")
local comments_api = require("atlas.pulls.providers.azure.api.comments")
local users = require("atlas.providers.azure.users")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	opts = opts or {}
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/reviewers",
		service.url_encode(pr.repo.owner),
		service.url_encode(pr.repo.repo_name),
		tostring(pr.id)
	)
	local cache_key = "reviewers:" .. endpoint
	if not opts.force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local reviewers = mapper.to_reviewers(result.value)
		service.set_cache(cache_key, reviewers)
		on_done(reviewers, nil)
	end, { action = "Fetch pull request reviewers", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean, commit_hash?: string }|nil
---@param include_hunks boolean
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_review(pr, opts, include_hunks, on_done)
	local commit_hash = (opts or {}).commit_hash or pr.source.commit_hash
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s",
		service.url_encode(pr.repo.owner),
		service.url_encode(pr.repo.repo_name),
		tostring(pr.id)
	)
	local cache_key = (include_hunks and "review-threads:" or "review:") .. endpoint .. ":" .. commit_hash
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = request_scope.new()
	local context = { action = "Fetch pull request review", repo = pr.repo_full_name, id = pr.id }
	scope.run(function(done)
		return changes.fetch_iteration(pr, commit_hash, done)
	end, function(iteration, err)
		if err then
			on_done(nil, err)
			return
		end
		local query = service.build_query({ ["$iteration"] = iteration, ["$baseIteration"] = 0 })
		local starts = {
			reviewers = function(done)
				return M.fetch_reviewers(pr, opts, done)
			end,
			comments = function(done)
				return service.request("GET", endpoint .. "/threads" .. query, nil, done, context)
			end,
		}
		if include_hunks then
			starts.files = function(done)
				return changes.fetch_file_diffs(pr, iteration, opts, done)
			end
		end
		scope.all(starts, function(values, errors)
			local error = errors.comments or errors.files or errors.reviewers
			if error then
				on_done(nil, error)
				return
			end
			local comments = mapper.to_review_comments(values.comments.value, pr)
			local files = {}
			for _, file in ipairs(values.files or {}) do
				files[file.path] = file
				if file.old_path then
					files[file.old_path] = file
				end
			end
			for _, comment in ipairs(comments) do
				local inline = comment.inline
				local file = inline and files[inline.path]
				if file and not comment.parent_id then
					local side = inline.to and "new" or "old"
					local line = inline.to or inline.from
					for _, hunk in ipairs(file.hunks) do
						local start = hunk[side .. "_start"]
						if line >= start and line < start + hunk[side .. "_count"] then
							comment.hunk = hunk
							break
						end
					end
				end
			end
			local data = {
				review = { pending = false, commit_hash = commit_hash },
				comments = comments,
				tasks = {},
				reviewers = values.reviewers or {},
				history = {},
			}
			service.set_cache(cache_key, data)
			on_done(data, nil)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean, commit_hash?: string }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	return fetch_review(pr, opts, false, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean, commit_hash?: string }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_threads(pr, opts, on_done)
	return fetch_review(pr, opts, true, on_done)
end

---@param pr PullRequest
---@param vote integer
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function set_vote(pr, vote, body, on_done)
	local scope = request_scope.new()
	scope.run(users.fetch_user, function(user, user_err)
		if user_err then
			on_done(false, user_err)
			return
		end
		local endpoint = string.format(
			"/%s/_apis/git/repositories/%s/pullrequests/%s/reviewers/%s",
			service.url_encode(pr.repo.owner),
			service.url_encode(pr.repo.repo_name),
			tostring(pr.id),
			service.url_encode(user.id)
		)
		scope.run(function(done)
			return service.request("PUT", endpoint, { id = user.id, vote = vote }, done, {
				action = "Update pull request vote",
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
			scope.run(function(done)
				return comments_api.add_comment(pr, body, nil, done)
			end, function(comment, comment_err)
				on_done(comment ~= nil, comment_err)
			end)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve(pr, _review, body, on_done)
	return set_vote(pr, 10, body, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.request_changes(pr, _review, body, on_done)
	return set_vote(pr, -5, body, on_done)
end

return M
