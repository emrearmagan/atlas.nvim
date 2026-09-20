local utils = require("atlas.pulls.pipelines.utils")

local M = {}

local STATES = {
	success = "SUCCESSFUL",
	failure = "FAILED",
	cancelled = "CANCELED",
	skipped = "SKIPPED",
}

local ESCAPES = { ["%3B"] = ";", ["%5D"] = "]", ["%0D"] = "\r", ["%0A"] = "\n", ["%25"] = "%" }

---@param line PullsLogLine
---@param colon_groups boolean
---@return string|nil, string|nil
local function marker(line, colon_groups)
	local offset = line.timestamp and line.text:sub(1, #line.timestamp) == line.timestamp and #line.timestamp + 1 or 0
	local body = line.text:sub(offset + 1)
	local command, properties, message = body:match("^##%[([%a%-]+)([^%]]*)%](.*)$")
	if command == "group" then
		return command, message
	elseif command == "endgroup" or command == "start-action" or command == "end-action" then
		return command, properties
	end
	if colon_groups then
		local name = body:match("^::group::(.*)$")
		if name then
			return "group", name
		elseif body:match("^::endgroup::%s*$") then
			return "endgroup"
		end
	end
end

---@param text string
---@return table<string, string>
local function properties(text)
	local result = {}
	for key, value in text:gmatch("([%w_]+)=([^;]*)") do
		result[key] = value:gsub("%%[%x][%x]", ESCAPES)
	end
	return result
end

---@param log PullsLog
---@return (PullsLogLine|PullsLogGroup)[]
function M.parse(log)
	---@type (PullsLogLine|PullsLogGroup)[]
	local entries = {}
	---@type { group: PullsLogGroup, id?: string }[]
	local stack = {}

	-- Runner groups may contain echoed ::group:: commands.
	local colon_groups = true
	for _, line in ipairs(log.lines) do
		if marker(line, false) == "group" then
			colon_groups = false
			break
		end
	end

	for _, line in ipairs(log.lines) do
		local command, value = marker(line, colon_groups)
		local parent = stack[#stack]
		local current = parent and parent.group.entries or entries

		if command == "group" then
			local group = { name = value, timestamp = line.timestamp, entries = {} }
			current[#current + 1] = group
			stack[#stack + 1] = { group = group }
		elseif command == "endgroup" and parent and not parent.id then
			parent.group.duration = utils.duration(parent.group.timestamp, line.timestamp)
			stack[#stack] = nil
		elseif command == "start-action" then
			---@cast value string
			local action = properties(value)
			local group = {
				name = action.display,
				timestamp = line.timestamp,
				entries = {},
			}
			current[#current + 1] = group
			stack[#stack + 1] = { group = group, id = action.id }
		elseif command == "end-action" and parent then
			---@cast value string
			local action = properties(value)
			if action.id == parent.id then
				parent.group.state = STATES[action.conclusion]
				local milliseconds = tonumber(action.duration_ms)
				parent.group.duration = milliseconds and milliseconds / 1000 or nil
				stack[#stack] = nil
			else
				current[#current + 1] = line
			end
		else
			current[#current + 1] = line
		end
	end

	return entries
end

---@param entries (PullsLogLine|PullsLogGroup)[]
---@param started string
---@param fraction number
---@return PullsLogLine|PullsLogGroup|nil
local function find_after(entries, started, fraction)
	for _, entry in ipairs(entries) do
		if entry.timestamp then
			local second = entry.timestamp:sub(1, 19)
			if
				second > started
				or (second == started and (tonumber(entry.timestamp:match("(%.%d+)Z$")) or 0) > fraction)
			then
				return entry
			end
		end
		if entry.entries then
			local target = find_after(entry.entries, started, fraction)
			if target then
				return target
			end
		end
	end
end

---@param entries (PullsLogLine|PullsLogGroup)[]
---@param name string
---@param range { first: string, last: string, fraction: number }
---@param matches (PullsLogLine|PullsLogGroup)[]
local function find_groups(entries, name, range, matches)
	for _, entry in ipairs(entries) do
		if entry.timestamp then
			local second = entry.timestamp:sub(1, 19)
			if second >= range.first and second <= range.last then
				local fraction = tonumber(entry.timestamp:match("(%.%d+)Z$")) or 0
				if
					(second ~= range.first or fraction >= range.fraction)
					and (second ~= range.last or fraction <= range.fraction)
				then
					---@type string|nil
					local title = entry.name
					if not entry.entries then
						---@cast entry PullsLogLine
						local command, value = marker(entry, false)
						if command == "group" then
							title = value
						elseif command == "start-action" then
							---@cast value string
							title = properties(value).display
						end
					end
					if title and vim.trim(title):lower():gsub("%s+", " ") == name then
						matches[#matches + 1] = entry
					end
				end
			end
		end
		if entry.entries then
			find_groups(entry.entries, name, range, matches)
		end
		if #matches > 1 then
			return
		end
	end
end

---@param entries (PullsLogLine|PullsLogGroup)[]
---@param step PullsPipelineStep
---@return PullsLogLine|PullsLogGroup|nil
function M.step_target(entries, step)
	if not step.started_at then
		return nil
	end

	local started = step.started_at:sub(1, 19)
	local fraction = tonumber(step.started_at:match("(%.%d+)Z$")) or 0
	local time = vim.fn.strptime("%Y-%m-%dT%H:%M:%S%z", started .. "+0000")
	local range = {
		first = os.date("!%Y-%m-%dT%H:%M:%S", time - 1),
		last = os.date("!%Y-%m-%dT%H:%M:%S", time + 1),
		fraction = fraction,
	}
	local matches = {}
	find_groups(entries, vim.trim(step.name):lower():gsub("%s+", " "), range, matches)
	if #matches == 1 then
		return matches[1]
	end
	return find_after(entries, started, fraction)
end

return M
