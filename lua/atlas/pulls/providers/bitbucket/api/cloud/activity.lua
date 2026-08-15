local M = {}

local comments = require("atlas.pulls.providers.bitbucket.api.comments")
local mapper = require("atlas.pulls.providers.bitbucket.api.cloud.mapper")
local service = require("atlas.pulls.providers.bitbucket.api.service")

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

	return service.fetch_all_values(activity_url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_activities_list(result), nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_conversation(pr, opts, on_done)
	local cancelled = false
	local comments_handle, activity_handle
	comments_handle = comments.fetch_comments(pr, opts, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end

		local general_comments = {}
		for _, comment in ipairs(result or {}) do
			if comment.inline == nil and comment.file == nil then
				table.insert(general_comments, comment)
			end
		end
		activity_handle = M.fetch_activity(pr, opts, function(events)
			if cancelled then
				return
			end
			local timeline = {}
			for _, event in ipairs(events or {}) do
				if event.kind ~= "comment" then
					table.insert(timeline, event)
				end
			end
			on_done({ comments = general_comments, events = timeline }, nil)
		end)
	end)

	return {
		cancel = function()
			cancelled = true
			if comments_handle then
				comments_handle.cancel()
			end
			if activity_handle then
				activity_handle.cancel()
			end
		end,
	}
end

return M
