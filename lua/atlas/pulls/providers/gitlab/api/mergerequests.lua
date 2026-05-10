local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local normalizer = require("atlas.pulls.providers.gitlab.api.normalizer")
local logger = require("atlas.core.logger")

---@param params table<string, any>
---@return string
local function build_query(params)
	local parts = {}
	for k, v in pairs(params or {}) do
		if v ~= nil and v ~= "" then
			table.insert(parts, k .. "=" .. service.url_encode(tostring(v)))
		end
	end
	if #parts == 0 then
		return ""
	end
	return "?" .. table.concat(parts, "&")
end

---@param view AtlasGitLabPullsViewConfig
---@param opts { force_load?: boolean, pagelen?: number }|nil
---@param on_done fun(groups: PullsGroup[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_mrs(view, opts, on_done)
	opts = opts or {}
	local params = {
		scope = view.scope or "assigned_to_me",
		state = view.state or "opened",
		per_page = tostring(opts.pagelen or 50),
		order_by = view.order_by or "updated_at",
		sort = view.sort or "desc",
	}
	if view.labels then
		params.labels = view.labels
	end
	if view.milestone then
		params.milestone = view.milestone
	end
	if view.assignee_username then
		params.assignee_username = view.assignee_username
	end
	if view.author_username then
		params.author_username = view.author_username
	end
	if view.search and view.search ~= "" then
		params.search = view.search
	end
	if type(view.extra_params) == "table" then
		for k, v in pairs(view.extra_params) do
			params[k] = v
		end
	end

	local endpoint = "/merge_requests" .. build_query(params)
	local cache_key = "gitlab_pulls:list:" .. endpoint

	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitLab list MRs", { endpoint = endpoint })
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local groups = normalizer.normalize_mrs_to_groups(type(result) == "table" and result or {})
		service.set_memory_cache(cache_key, groups)
		on_done(groups, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_load?: boolean, force_refresh?: boolean }|nil
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_mr(pr, opts, on_done)
	opts = opts or {}
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:get:%s!%d", path, iid)
	if not (opts.force_load or opts.force_refresh) then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local mr = normalizer.normalize_mr(result)
		if mr then
			service.set_memory_cache(cache_key, mr)
		end
		on_done(mr, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_description(pr, opts, on_done)
	return M.get_mr(pr, opts, function(mr, err)
		if err or mr == nil then
			on_done(nil, err)
			return
		end
		on_done(tostring(mr.description or ""), nil)
	end)
end

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
end

---@param pr PullRequest
local function bust_caches(pr)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		return
	end
	service.delete_memory_cache(string.format("gitlab_pulls:get:%s!%d", path, iid))
end

---@param pr PullRequest
---@param payload table
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_mr(pr, payload, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		bust_caches(pr)
		on_done(type(result) == "table" and normalizer.normalize_mr(result) or nil, nil)
	end)
end

---@param pr PullRequest
---@param state_event "close"|"reopen"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(pr, state_event, on_done)
	return M.update_mr(pr, { state_event = state_event }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param title string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_title(pr, title, on_done)
	return M.update_mr(pr, { title = title }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_reviewer_ids(pr, ids, on_done)
	-- GitLab requires non-empty array; pass {0} to clear.
	local body = { reviewer_ids = (#ids == 0) and { 0 } or ids }
	return M.update_mr(pr, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_assignee_ids(pr, ids, on_done)
	local body = { assignee_ids = (#ids == 0) and { 0 } or ids }
	return M.update_mr(pr, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve(pr, on_done)
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
		bust_caches(pr)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.unapprove(pr, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d/unapprove", service.url_encode(path), iid)
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_caches(pr)
		on_done(true, nil)
	end)
end

---@class GitLabMergeOpts
---@field squash boolean|nil
---@field should_remove_source_branch boolean|nil
---@field merge_commit_message string|nil
---@field squash_commit_message string|nil

---@param pr PullRequest
---@param opts GitLabMergeOpts|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.merge(pr, opts, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	opts = opts or {}
	local body = {}
	if opts.squash ~= nil then
		body.squash = opts.squash == true
	end
	if opts.should_remove_source_branch ~= nil then
		body.should_remove_source_branch = opts.should_remove_source_branch == true
	end
	if type(opts.merge_commit_message) == "string" and opts.merge_commit_message ~= "" then
		body.merge_commit_message = opts.merge_commit_message
	end
	if type(opts.squash_commit_message) == "string" and opts.squash_commit_message ~= "" then
		body.squash_commit_message = opts.squash_commit_message
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/merge", service.url_encode(path), iid)
	return service.request("PUT", endpoint, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_caches(pr)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_reviewers(pr, opts, on_done)
	return M.get_mr(pr, opts, function(mr, err)
		if err or mr == nil then
			on_done(nil, err)
			return
		end
		local raw = type(mr._raw) == "table" and mr._raw or {}
		local reviewers = {}
		for _, r in ipairs(raw.reviewers or {}) do
			if type(r) == "table" and type(r.username) == "string" then
				table.insert(reviewers, {
					name = r.username,
					nickname = r.username,
					decision = "pending",
				})
			end
		end
		on_done(reviewers, nil)
	end)
end

return M
