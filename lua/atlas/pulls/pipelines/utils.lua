local M = {}

local STATE_PRIORITY = {
	UNKNOWN = 0,
	SKIPPED = 1,
	STOPPED = 2,
	SUCCESSFUL = 3,
	PENDING = 4,
	QUEUED = 5,
	MANUAL = 6,
	PAUSED = 7,
	CANCELED = 8,
	INPROGRESS = 9,
	FAILED = 10,
}

local STATE_LABEL = {
	UNKNOWN = "Unknown",
	STOPPED = "Stopped",
	CANCELED = "Canceled",
	SKIPPED = "Skipped",
	PENDING = "Pending",
	QUEUED = "Queued",
	PAUSED = "Paused",
	MANUAL = "Manual",
	SUCCESSFUL = "Successful",
	INPROGRESS = "In progress",
	FAILED = "Failed",
}

local DISPLAY_PRIORITY = {
	FAILED = 1,
	INPROGRESS = 2,
	PAUSED = 3,
	MANUAL = 4,
	QUEUED = 5,
	PENDING = 6,
	CANCELED = 7,
	STOPPED = 7,
	UNKNOWN = 8,
	SUCCESSFUL = 9,
	SKIPPED = 10,
}

local MERGE_CHECK_STATE = {
	UNKNOWN = "muted",
	STOPPED = "muted",
	CANCELED = "warning",
	SKIPPED = "muted",
	PENDING = "inprogress",
	QUEUED = "inprogress",
	PAUSED = "warning",
	MANUAL = "warning",
	SUCCESSFUL = "successful",
	INPROGRESS = "inprogress",
	FAILED = "failed",
}

---@param pipeline PullsPipeline
---@return string
function M.display_name(pipeline)
	local suffix = pipeline.number and ("#" .. pipeline.number)
	if suffix and not vim.endswith(pipeline.name, suffix) then
		return pipeline.name .. " " .. suffix
	end
	return pipeline.name
end

---@param items { state: PullsPipelineState }[]
---@return PullsPipelineState
---@return table<PullsPipelineState, integer>
local function summarize(items)
	---@type PullsPipelineState
	local aggregate = "UNKNOWN"
	local counts = {
		UNKNOWN = 0,
		STOPPED = 0,
		CANCELED = 0,
		SKIPPED = 0,
		PENDING = 0,
		QUEUED = 0,
		PAUSED = 0,
		MANUAL = 0,
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

---@param started_at string|nil
---@param completed_at string|nil
---@return number|nil
function M.duration(started_at, completed_at)
	if type(started_at) ~= "string" or type(completed_at) ~= "string" then
		return nil
	end
	local times = {}
	for _, timestamp in ipairs({ started_at, completed_at }) do
		local date = timestamp:sub(1, 19):gsub(" ", "T")
		local zone = (timestamp:match("([+-]%d%d:?%d%d)$") or "+0000"):gsub(":", "")
		local seconds = vim.fn.strptime("%Y-%m-%dT%H:%M:%S%z", date .. "+0000")
		if seconds <= 0 then
			return nil
		end
		local offset = tonumber(zone:sub(2, 3)) * 3600 + tonumber(zone:sub(4, 5)) * 60
		seconds = seconds - (zone:sub(1, 1) == "+" and offset or -offset)
		local fraction = timestamp:match("[.,](%d+)")
		times[#times + 1] = seconds + tonumber("0." .. (fraction or "0"))
	end
	local elapsed = times[2] - times[1]
	return elapsed >= 0 and elapsed or nil
end

---@param state string
---@return string
function M.state_label(state)
	return STATE_LABEL[state:upper()] or STATE_LABEL.UNKNOWN
end

---@generic T: { state: string }
---@param items T[]
---@return T[]
function M.sort_by_state(items)
	local indexed = {}
	for index, item in ipairs(items) do
		table.insert(indexed, { item = item, index = index })
	end
	table.sort(indexed, function(a, b)
		local a_state = tostring(a.item.state or "UNKNOWN"):upper()
		local b_state = tostring(b.item.state or "UNKNOWN"):upper()
		local a_priority = DISPLAY_PRIORITY[a_state] or DISPLAY_PRIORITY.UNKNOWN
		local b_priority = DISPLAY_PRIORITY[b_state] or DISPLAY_PRIORITY.UNKNOWN
		if a_priority == b_priority then
			return a.index < b.index
		end
		return a_priority < b_priority
	end)

	local sorted = {}
	for _, entry in ipairs(indexed) do
		table.insert(sorted, entry.item)
	end
	return sorted
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
	local description = state == "MANUAL" and "awaiting manual action" or M.state_label(state):lower()
	return {
		key = "pipelines",
		state = MERGE_CHECK_STATE[state],
		label = label,
		details = { string.format("%d of %d %s", counts[state], #items, description) },
	}
end

return M
