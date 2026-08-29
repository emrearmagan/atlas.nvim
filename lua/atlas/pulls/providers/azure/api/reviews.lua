local M = {}

local diff_parser = require("atlas.core.git.diff_parser")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")
local mapper = require("atlas.pulls.providers.azure.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	opts = opts or {}
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s/reviewers",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
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

---@param endpoint string
---@param iteration integer
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_file_diffs(endpoint, iteration, on_done)
	local files = {}
	local scope = request_scope.new()
	local context = { action = "Fetch pull request thread snippets" }

	---@param skip integer
	local function fetch_page(skip)
		local query =
			service.build_query({ iteration = iteration, baseIteration = 0, ["$top"] = 100, ["$skip"] = skip })
		scope.run(function(done)
			return service.request("GET", endpoint .. "/filesdiff" .. query, nil, done, context, "7.2-preview.1")
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(files, mapper.to_diff_files(result.fileDiffs))
			if #result.fileDiffs == 100 then
				fetch_page(skip + 100)
				return
			end
			on_done(files, nil)
		end)
	end

	fetch_page(0)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param include_hunks boolean
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_review(pr, opts, include_hunks, on_done)
	local endpoint = string.format(
		"/%s/_apis/git/repositories/%s/pullrequests/%s",
		service.url_encode(pr.workspace),
		service.url_encode(pr.repo),
		tostring(pr.id)
	)
	local cache_key = (include_hunks and "review-threads:" or "review:") .. endpoint
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
		return service.request("GET", endpoint .. "/iterations", nil, done, context)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local iteration = result.value[#result.value].id
		local query = service.build_query({ ["$iteration"] = iteration, ["$baseIteration"] = 0 })
		local starts = {
			comments = function(done)
				return service.request("GET", endpoint .. "/threads" .. query, nil, done, context)
			end,
		}
		if include_hunks then
			starts.files = function(done)
				return fetch_file_diffs(endpoint, iteration, done)
			end
		end
		scope.all(starts, function(values, errors)
			local error = errors.comments or errors.files
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
				if include_hunks and inline and not comment.parent_id then
					comment.hunk = diff_parser.find_hunk(
						files[inline.path],
						inline.to and "new" or "old",
						inline.to or inline.from
					)
				end
			end
			local data = {
				review = { pending = false, commit_hash = pr.source.commit_hash },
				comments = comments,
				tasks = {},
				reviewers = pr.reviewers or {},
				history = {},
			}
			service.set_cache(cache_key, data)
			on_done(data, nil)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	return fetch_review(pr, opts, false, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_threads(pr, opts, on_done)
	return fetch_review(pr, opts, true, on_done)
end

return M
