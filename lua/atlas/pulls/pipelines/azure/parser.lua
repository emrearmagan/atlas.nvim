local utils = require("atlas.pulls.pipelines.utils")

local M = {}

---@param line PullsLogLine
---@return "section"|"end_section"|"group"|"end_group"|nil
---@return string|nil name
local function marker(line)
	local body = line.text:sub(line.timestamp and #line.timestamp + 2 or 1)
	local name = body:match("^##%[section%]Starting: (.*)$")
	if name then
		return "section", name
	elseif body:match("^##%[section%]Finishing: ") then
		return "end_section"
	end

	name = body:match("^##%[group%](.*)$")
	if name then
		return "group", name
	elseif body:match("^##%[endgroup%]") then
		return "end_group"
	end
end

---@param log PullsLog
---@return (PullsLogLine|PullsLogGroup)[]
function M.parse(log)
	---@type (PullsLogLine|PullsLogGroup)[]
	local entries = {}
	---@type { group: PullsLogGroup, section: boolean }[]
	local stack = {}

	for _, line in ipairs(log.lines) do
		local kind, name = marker(line)
		local parent = stack[#stack]
		local current = parent and parent.group.entries or entries

		if kind == "section" or kind == "group" then
			local group = { name = name, timestamp = line.timestamp, entries = {} }
			current[#current + 1] = group
			stack[#stack + 1] = { group = group, section = kind == "section" }
		elseif kind == "end_group" and parent and not parent.section then
			parent.group.duration = utils.duration(parent.group.timestamp, line.timestamp)
			stack[#stack] = nil
		elseif kind == "end_section" then
			-- A finished step also closes groups it left open.
			for index = #stack, 1, -1 do
				local frame = stack[index]
				if frame.section then
					frame.group.duration = utils.duration(frame.group.timestamp, line.timestamp)
					for last = #stack, index, -1 do
						stack[last] = nil
					end
					break
				end
			end
		else
			current[#current + 1] = line
		end
	end

	return entries
end

return M
