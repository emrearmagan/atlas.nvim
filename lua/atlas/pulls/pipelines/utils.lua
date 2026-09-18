local M = {}

local STATE_PRIORITY = {
	UNKNOWN = 0,
	STOPPED = 1,
	SUCCESSFUL = 2,
	INPROGRESS = 3,
	FAILED = 4,
}

local STATE_LABEL = {
	UNKNOWN = "unknown",
	STOPPED = "stopped",
	SUCCESSFUL = "successful",
	INPROGRESS = "in progress",
	FAILED = "failed",
}

local MERGE_CHECK_STATE = {
	UNKNOWN = "muted",
	STOPPED = "muted",
	SUCCESSFUL = "successful",
	INPROGRESS = "inprogress",
	FAILED = "failed",
}

---@param items { state: PullsPipelineState }[]
---@return PullsPipelineState
---@return table<PullsPipelineState, integer>
local function summarize(items)
	---@type PullsPipelineState
	local aggregate = "UNKNOWN"
	local counts = {
		UNKNOWN = 0,
		STOPPED = 0,
		SUCCESSFUL = 0,
		INPROGRESS = 0,
		FAILED = 0,
	}

	for _, item in ipairs(items) do
		local normalized = tostring(item.state or "UNKNOWN"):upper()
		if STATE_PRIORITY[normalized] == nil then
			normalized = "UNKNOWN"
		end
		local state = normalized --[[@as PullsPipelineState]]
		counts[state] = counts[state] + 1
		if STATE_PRIORITY[state] > STATE_PRIORITY[aggregate] then
			aggregate = state
		end
	end

	return aggregate, counts
end

---@param items { state: PullsPipelineState }[]
---@return PullsPipelineState
function M.aggregate_state(items)
	local state = summarize(items)
	return state
end

---@param items { state: PullsPipelineState }[]
---@param label string
---@return PullsMergeCheck|nil
function M.to_merge_check(items, label)
	if type(items) ~= "table" or #items == 0 then
		return nil
	end

	local state, counts = summarize(items)
	return {
		key = "pipelines",
		state = MERGE_CHECK_STATE[state],
		label = label,
		details = { string.format("%d of %d %s", counts[state], #items, STATE_LABEL[state]) },
	}
end

return M
