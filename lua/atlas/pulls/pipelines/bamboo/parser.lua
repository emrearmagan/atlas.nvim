local M = {}

---@type table<string, PullsPipelineState>
local states = { Success = "SUCCESSFUL", Failed = "FAILED" }

---@param log PullsLog
---@return (PullsLogLine|PullsLogGroup)[]
function M.parse(log)
	---@type (PullsLogLine|PullsLogGroup)[]
	local entries = {}
	---@type PullsLogGroup[]
	local stack = {}

	for _, line in ipairs(log.lines) do
		local offset = line.timestamp and #line.timestamp + 1 or 0
		local body = line.text:sub(offset + 1)
		local channel, timestamp, message = body:match("^(%a+)%s+(%d%d?%-%S+%-%d%d%d%d%s+%d%d:%d%d:%d%d)%s+(.*)$")
		if channel == "simple" or channel == "build" or channel == "error" or channel == "command" then
			line = { text = message, timestamp = timestamp }
		end
		local task_message = channel == "simple" and message or ""
		local name = task_message:match("^Starting task '(.*)' of type '.+'$")
		local parent = stack[#stack]
		local current = parent and parent.entries or entries

		if name then
			local group = { name = name, timestamp = timestamp, entries = {} }
			current[#current + 1] = group
			stack[#stack + 1] = group
		else
			current[#current + 1] = line
			local finished_name, result = task_message:match("^Finished task '(.*)' with result: (.+)$")
			if finished_name then
				for index = #stack, 1, -1 do
					if stack[index].name == finished_name then
						local group = stack[index]
						group.state = states[result]
						local started = vim.fn.strptime("%d-%b-%Y %H:%M:%S", group.timestamp)
						local finished = vim.fn.strptime("%d-%b-%Y %H:%M:%S", timestamp)
						if started > 0 and finished >= started then
							group.duration = finished - started
						end
						for last = #stack, index, -1 do
							stack[last] = nil
						end
						break
					end
				end
			end
		end
	end

	return entries
end

return M
