---@class AtlasLogRule
---@field pattern string Lua pattern.
---@field level PullsLogLevel|nil
---@field hl_group string|nil

local M = {}

local LEVELS = {
	error = "AtlasLogError",
	warn = "AtlasLogWarn",
	info = "AtlasLogInfo",
	debug = "AtlasLogDebug",
	success = "AtlasTextPositive",
	canceled = "AtlasTextMuted",
	skipped = "AtlasTextMuted",
}

local defaults = {
	{
		pattern = "^##%[error%]",
		replacement = "Error: ",
		level = "error",
		hl_group = "AtlasLogErrorLine",
		hl_eol = true,
	},
	{ pattern = "^##%[warning%]", replacement = "Warning: ", level = "warn" },
	{ pattern = "^##%[notice%]", replacement = "Notice: ", level = "info" },
	{ pattern = "^##%[debug%]", replacement = "Debug: ", level = "debug" },
	{ pattern = "^##%[command%]", replacement = "", hl_group = "AtlasLogCommand" },
	{ pattern = "^##%[section%]", replacement = "", hl_group = "AtlasLogGroup" },
	{ pattern = "^%[command%]", replacement = "", hl_group = "AtlasLogCommand" },
	{ pattern = "^%s*%++%s", hl_group = "AtlasLogCommand" },
	{
		pattern = "^::error::",
		replacement = "Error: ",
		level = "error",
		hl_group = "AtlasLogErrorLine",
		hl_eol = true,
	},
	{
		pattern = "^::error%s+.-::",
		replacement = "Error: ",
		level = "error",
		hl_group = "AtlasLogErrorLine",
		hl_eol = true,
	},
	{ pattern = "^::warning::", replacement = "Warning: ", level = "warn" },
	{ pattern = "^::warning%s+.-::", replacement = "Warning: ", level = "warn" },
	{ pattern = "^::notice::", replacement = "Notice: ", level = "info" },
	{ pattern = "^::notice%s+.-::", replacement = "Notice: ", level = "info" },
	{ pattern = "^::debug::", replacement = "Debug: ", level = "debug" },
	{ pattern = "^::debug%s+.-::", replacement = "Debug: ", level = "debug" },
	{ pattern = "^%s*%[error%]", level = "error" },
	{ pattern = "^%s*error:", level = "error" },
	{ pattern = "^%s*%[warn%]", level = "warn" },
	{ pattern = "^%s*%[warning%]", level = "warn" },
	{ pattern = "^%s*warn:", level = "warn" },
	{ pattern = "^%s*warning:", level = "warn" },
	{ pattern = "^%s*%[info%]", level = "info" },
	{ pattern = "^%s*info:", level = "info" },
	{ pattern = "^%s*%[notice%]", level = "info" },
	{ pattern = "^%s*notice:", level = "info" },
	{ pattern = "^%s*%[debug%]", level = "debug" },
	{ pattern = "^%s*debug:", level = "debug" },
}

---@param rule AtlasLogRule
---@param text string
---@return boolean
local function matches(rule, text)
	local highlight = rule.hl_group or LEVELS[rule.level]
	if type(highlight) ~= "string" or (rule.level and not LEVELS[rule.level]) then
		return false
	end
	if rule.hl_group and vim.fn.hlexists(rule.hl_group) == 0 then
		return false
	end
	return text:find(rule.pattern) ~= nil
end

---@param custom_rules AtlasLogRule[]|nil
---@return fun(value: string, is_group: boolean, level?: PullsLogLevel): string, table[]
---@return table<PullsLogLevel, integer> counts
function M.new(custom_rules)
	local rules = type(custom_rules) == "table" and custom_rules or {}
	local counts = { error = 0, warn = 0, success = 0, canceled = 0, skipped = 0 }

	return function(value, is_group, level)
		local body = value:gsub("\r", " ")
		local hl_eol
		local highlight = is_group and "AtlasLogGroup" or LEVELS[level]
		if is_group then
			body = body:gsub("[%z\1-\31\127]", " ")
		else
			local normalized = body:lower()
			for _, rule in ipairs(defaults) do
				local _, last = normalized:find(rule.pattern)
				if last then
					if rule.replacement then
						body = rule.replacement .. body:sub(last + 1)
					end
					level = rule.level
					highlight = rule.hl_group or LEVELS[level]
					hl_eol = rule.hl_eol
					break
				end
			end
		end

		local custom
		for _, rule in ipairs(rules) do
			local ok, matched = pcall(matches, rule, body)
			if ok and matched then
				custom = rule
			end
		end
		if custom then
			level = custom.level or level
			highlight = custom.hl_group or LEVELS[custom.level]
			hl_eol = nil
		end

		if counts[level] then
			counts[level] = counts[level] + 1
		end
		local spans = {}
		if highlight and #body > 0 then
			spans[1] = { start_col = 0, end_col = #body, hl_group = highlight, hl_eol = hl_eol }
		end
		return body, spans
	end,
		counts
end

return M
