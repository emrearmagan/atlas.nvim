local M = {}

local MODULES = {
	github = "atlas.pulls.providers.github",
	bitbucket = "atlas.pulls.providers.bitbucket",
	gitlab = "atlas.pulls.providers.gitlab",
}

local PIPELINE_STATE_PRIORITY = {
	UNKNOWN = 0,
	STOPPED = 1,
	SUCCESSFUL = 2,
	INPROGRESS = 3,
	FAILED = 4,
}

local PIPELINE_STATE_LABEL = {
	UNKNOWN = "unknown",
	STOPPED = "stopped",
	SUCCESSFUL = "successful",
	INPROGRESS = "in progress",
	FAILED = "failed",
}

local PIPELINE_CHECK_STATE = {
	UNKNOWN = "muted",
	STOPPED = "muted",
	SUCCESSFUL = "successful",
	INPROGRESS = "inprogress",
	FAILED = "failed",
}

---@param items { state: string }[]
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
---@return table<string, integer>
function M.aggregate_pipeline_state(items)
	local aggregate = "UNKNOWN"
	local counts = {
		UNKNOWN = 0,
		STOPPED = 0,
		SUCCESSFUL = 0,
		INPROGRESS = 0,
		FAILED = 0,
	}

	for _, item in ipairs(items or {}) do
		local state = tostring(item.state or "UNKNOWN"):upper()
		if PIPELINE_STATE_PRIORITY[state] == nil then
			state = "UNKNOWN"
		end
		counts[state] = counts[state] + 1
		if PIPELINE_STATE_PRIORITY[state] > PIPELINE_STATE_PRIORITY[aggregate] then
			aggregate = state
		end
	end

	return aggregate, counts
end

---@param items { state: string }[]
---@param label string
---@return PullsMergeCheck|nil
function M.pipelines_check(items, label)
	if type(items) ~= "table" or #items == 0 then
		return nil
	end

	local state, counts = M.aggregate_pipeline_state(items)
	return {
		key = "pipelines",
		state = PIPELINE_CHECK_STATE[state],
		label = label,
		details = { string.format("%d of %d %s", counts[state], #items, PIPELINE_STATE_LABEL[state]) },
	}
end

---@param id string
---@return PullsProvider|nil
function M.get(id)
	local path = MODULES[id]
	return path and require(path) or nil
end

return M
