local M = {}

local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(issue, opts, on_done)
	---@cast issue ShortcutIssue
	local story_id = issue.id
	local cache_key = "story:" .. tostring(story_id) .. ":history"
	opts = opts or {}

	if not opts.force_refresh then
		local cached, found = service.get_memory_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/stories/%d/history", story_id)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table[]
		local entries = mapper.to_history(result)
		service.set_memory_cache(cache_key, entries)
		on_done(entries, nil)
	end, {
		action = "Fetch Shortcut Story history",
		issue_key = tostring(story_id),
	})
end

return M
