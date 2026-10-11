local M = {}

---@param log PullsLog
---@return (PullsLogLine|PullsLogGroup)[]
function M.parse(log)
	---@type PullsLogLine[]
	local lines = {}
	---@type table<string, PullsLogLine>
	local streams = {}

	for _, line in ipairs(log.lines) do
		local body = line.text:sub(line.timestamp and #line.timestamp + 2 or 1)
		local stream, append, message = body:match("^(%x%x[OE])([+ ])(.*)$")
		if stream then
			local previous = streams[stream]
			if append == "+" and previous then
				previous.text = previous.text .. message
			else
				local output = { text = message, timestamp = line.timestamp }
				lines[#lines + 1] = output
				streams[stream] = output
			end
		else
			lines[#lines + 1] = { text = body, timestamp = line.timestamp }
		end
	end

	---@type (PullsLogLine|PullsLogGroup)[]
	local entries = {}
	---@type { group: PullsLogGroup, key: string, epoch: number }[]
	local stack = {}

	for _, line in ipairs(lines) do
		local body = line.text
		local epoch, section, flags, title = body:match("^section_start:(%d+):([%w_.%-]+)([^\r]*)\r?(.*)$")
		local parent = stack[#stack]
		local current = parent and parent.group.entries or entries

		if epoch and (flags == "" or flags:match("^%[.-%]$")) then
			local group = { name = title ~= "" and title or section, timestamp = line.timestamp, entries = {} }
			current[#current + 1] = group
			stack[#stack + 1] = {
				group = group,
				key = section,
				epoch = tonumber(epoch) --[[@as number]],
			}
		else
			local ended, end_section = body:match("^section_end:(%d+):([%w_.%-]+)\r?%s*$")
			local closed = false
			if ended then
				for index = #stack, 1, -1 do
					local frame = stack[index]
					if frame.key == end_section then
						local finish = tonumber(ended)
						if finish >= frame.epoch then
							frame.group.duration = finish - frame.epoch
						end
						for last = #stack, index, -1 do
							stack[last] = nil
						end
						closed = true
						break
					end
				end
			end
			if not closed then
				current[#current + 1] = line
			end
		end
	end

	return entries
end

return M
