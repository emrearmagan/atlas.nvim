local M = {}

local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local changes_api = require("atlas.pulls.providers.gitlab.api.changes")
local diff_parser = require("atlas.core.git.diff_parser")
local service = require("atlas.providers.gitlab.client").pulls

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param path string
---@param iid integer
local function bust_review_caches(path, iid)
	service.delete_memory_cache(string.format("gitlab_pulls:comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:activity:%s!%d", path, iid))
end

---@param pr PullRequest
local function bust_pull_request_cache(pr)
	local path, iid = project_iid(pr)
	if path ~= "" and iid then
		service.delete_memory_cache(string.format("gitlab_pulls:get:%s!%d", path, iid))
	end
end

---@param files DiffFile[]
---@return table<string, DiffFile>
local function index_files(files)
	local by_path = {}
	for _, file in ipairs(files) do
		if file.path ~= "" then
			by_path[file.path] = file
		end
		if file.old_path and file.old_path ~= "" and by_path[file.old_path] == nil then
			by_path[file.old_path] = file
		end
	end
	return by_path
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch(pr, opts, on_done)
	local comments_request
	local changes_request
	local cancelled = false
	comments_request = comments_api.fetch(pr, opts, function(result, err)
		if not result then
			on_done(nil, err)
			return
		end
		changes_request = changes_api.fetch_diff(pr, opts, function(files)
			if cancelled then
				return
			end
			local files_by_path = index_files(files or {})
			local comments = {}
			local pending = false
			for _, comment in ipairs(result) do
				pending = pending or comment.state == "PENDING"
				if comment.inline then
					local side = comment.inline.to ~= nil and "new" or "old"
					local line = comment.inline.to or comment.inline.from
					if line then
						comment.inline_hunk = diff_parser.find_hunk(files_by_path[comment.inline.path], side, line)
					end
				end
				if comment.inline or comment.file then
					table.insert(comments, comment)
				end
			end
			on_done({
				review = { id = nil, commit_hash = nil, pending = pending },
				comments = comments,
				tasks = {},
			}, nil)
		end)
	end)
	return {
		cancel = function()
			cancelled = true
			if comments_request then
				comments_request.cancel()
			end
			if changes_request then
				changes_request.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
function M.fetch_context(pr, _opts, on_done)
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
	for _, list in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
		for _, user in ipairs(list) do
			add(user)
		end
	end
	on_done({ authors = authors }, nil)
end

---@param pr PullRequest
---@param _review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.discard(pr, _review, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end

	local prefix = string.format("/projects/%s/merge_requests/%d/draft_notes", service.url_encode(path), iid)
	local current
	local cancelled = false
	local function delete_next(drafts, index)
		if cancelled then
			return
		end
		local draft = drafts[index]
		if not draft then
			bust_review_caches(path, iid)
			on_done(true, nil)
			return
		end
		current = service.request("DELETE", prefix .. "/" .. tostring(draft.id), nil, function(_, err)
			if err then
				on_done(false, err)
				return
			end
			delete_next(drafts, index + 1)
		end)
	end

	current = service.fetch_all_pages(prefix .. "?per_page=100", function(drafts, err)
		if err then
			on_done(false, err)
			return
		end
		delete_next(drafts or {}, 1)
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
---@param reviewer_state "reviewed"|"requested_changes"|nil
---@param body string|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.publish(pr, reviewer_state, body, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end

	local payload
	if body and vim.trim(body) ~= "" then
		payload = { note = body }
	end
	if reviewer_state then
		payload = payload or {}
		payload.reviewer_state = reviewer_state
	end

	local endpoint =
		string.format("/projects/%s/merge_requests/%d/draft_notes/bulk_publish", service.url_encode(path), iid)
	return service.request("POST", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_review_caches(path, iid)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function approve_pull_request(pr, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d/approve", service.url_encode(path), iid)
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_pull_request_cache(pr)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit(pr, _review, body, on_done)
	return M.publish(pr, "reviewed", body, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve(pr, _review, body, on_done)
	local cancelled = false
	local current
	current = M.publish(pr, "reviewed", body, function(ok, err)
		if cancelled then
			return
		end
		if not ok then
			on_done(false, err)
			return
		end
		current = approve_pull_request(pr, on_done)
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
---@return { cancel: fun() }|nil
function M.request_changes(pr, _review, body, on_done)
	return M.publish(pr, "requested_changes", body, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(by_username: table<string, string>|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewer_states(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:reviewer_states:%s!%d", path, iid)
	if opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/reviewers", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local by_username = {}
		for _, item in ipairs(result) do
			by_username[item.user.username] = item.state
		end
		service.set_memory_cache(cache_key, by_username)
		on_done(by_username, nil)
	end)
end

return M
