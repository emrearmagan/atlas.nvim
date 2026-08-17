local M = {}

local comments = require("atlas.pulls.providers.bitbucket.api.comments")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local tasks = require("atlas.pulls.providers.bitbucket.api.tasks")

---@param all_comments PullsComment[]
---@param all_tasks PullsComment[]
---@return PullsComment[], PullsComment[]
local function global_items(all_comments, all_tasks)
	local comments_by_id = {}
	for _, comment in ipairs(all_comments) do
		comments_by_id[tostring(comment.id)] = comment
	end

	local global_by_id = {}
	local visiting = {}

	---@param comment PullsComment
	---@return boolean
	local function is_global(comment)
		local id = tostring(comment.id)
		if global_by_id[id] ~= nil then
			return global_by_id[id]
		end
		if visiting[id] then
			global_by_id[id] = false
			return false
		end
		if comment.inline ~= nil or comment.file ~= nil then
			global_by_id[id] = false
			return false
		end

		local parent_id = comment.parent_id and tostring(comment.parent_id) or nil
		if parent_id == nil then
			global_by_id[id] = true
			return true
		end

		local parent = comments_by_id[parent_id]
		if parent == nil then
			global_by_id[id] = false
			return false
		end

		visiting[id] = true
		local result = is_global(parent)
		visiting[id] = nil
		global_by_id[id] = result
		return result
	end

	local result_comments = {}
	for _, comment in ipairs(all_comments) do
		if is_global(comment) then
			table.insert(result_comments, comment)
		end
	end

	local result_tasks = {}
	for _, task in ipairs(all_tasks) do
		local parent_id = task.parent_id and tostring(task.parent_id) or nil
		if parent_id == nil or global_by_id[parent_id] == true then
			table.insert(result_tasks, task)
		end
	end

	return result_comments, result_tasks
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, _opts, on_done)
	local activity_url = tostring((pr._raw.links or {}).activity or "")
	if activity_url == "" then
		on_done({}, nil)
		return nil
	end
	local sep = activity_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=50&fields=-values.comment,-values.pull_request", activity_url, sep)

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_activities_list(result), nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], tasks: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_conversation(pr, opts, on_done)
	local requests = request_scope.new()
	requests.all({
		comments = function(done)
			return comments.fetch_global_comments(pr, opts, done)
		end,
		tasks = function(done)
			return tasks.fetch_tasks(pr, opts, done)
		end,
		events = function(done)
			return M.fetch_activity(pr, opts, done)
		end,
	}, function(values, errors)
		if errors.comments and errors.tasks and errors.events then
			on_done(nil, errors.comments or errors.tasks or errors.events)
			return
		end

		local global_comments, global_tasks = global_items(values.comments or {}, values.tasks or {})
		local timeline = {}
		for _, event in ipairs(values.events or {}) do
			if event.kind ~= "comment" then
				table.insert(timeline, event)
			end
		end
		on_done({ comments = global_comments, tasks = global_tasks, events = timeline }, nil)
	end)
	return requests
end

return M
