---@class PullsLog
---@field raw string
---@field lines PullsLogLine[]|nil

---@class PullsLogLine
---@field text string
---@field timestamp string|nil

---@class PullsLogGroup
---@field name string
---@field timestamp string|nil
---@field duration number|nil Seconds.
---@field state PullsPipelineState|nil
---@field entries (PullsLogLine|PullsLogGroup)[]

local M = {}

---@param text string
---@return string|nil
local function timestamp_prefix(text)
	local _, last = text:find("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d")
	if not last then
		return nil
	end
	local fraction = text:sub(last + 1):match("^[.,]%d+")
	last = last + #(fraction or "")
	local suffix = text:sub(last + 1)
	local zone = suffix:match("^[Zz]") or suffix:match("^[+%-]%d%d:%d%d") or suffix:match("^[+%-]%d%d%d%d")
	last = last + #(zone or "")
	local separator = text:sub(last + 1, last + 1)
	if separator == "" or separator == " " or separator == "\t" then
		return text:sub(1, last)
	end
end

---@param raw string
---@return PullsLogLine[]
local function clean_lines(raw)
	if raw == "" then
		return {}
	end

	raw = raw:gsub("\239\187\191", ""):gsub("\r\n", "\n")
	raw = raw:gsub("\27%][^\7\27]*\7", "")
	raw = raw:gsub("\27[%]PX^_][^\27]*\27\\", "")
	raw = raw:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
	raw = raw:gsub("\27[ -/]*[0-~]", "")
	raw = raw:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	local lines = vim.split(raw, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end

	---@type PullsLogLine[]
	local entries = {}
	for _, line in ipairs(lines) do
		local text = line:gsub("\27%[[0-?]*[ -/]*$", "")
		entries[#entries + 1] = { text = text, timestamp = timestamp_prefix(text) }
	end
	return entries
end

---@param log PullsLog
---@param parse PullsPipelineParse|nil
---@return (PullsLogLine|PullsLogGroup)[]
function M.parse(log, parse)
	log.lines = clean_lines(log.raw)
	return parse and parse(log) or log.lines
end

return M
