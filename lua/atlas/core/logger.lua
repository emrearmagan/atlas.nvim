local M = {}

local LOG_FILE_NAME = "atlas.log"
local DEFAULT_LEVEL = "INFO"

---@alias AtlasLogLevel "DEBUG"|"INFO"|"WARN"|"ERROR"

local function now_iso()
	return os.date("%Y-%m-%dT%H:%M:%S")
end

---@param s string
---@return string
local function sanitize(s)
	local out = tostring(s):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return out
end

---@param value any
---@return string
local function to_text(value)
	if type(value) == "string" then
		return sanitize(value)
	end
	return sanitize(vim.inspect(value))
end

---@param context table|nil
---@return string
local function context_suffix(context)
	if context == nil then
		return ""
	end

	if type(context) ~= "table" then
		return " | " .. to_text(context)
	end

	local keys = {}
	for k, _ in pairs(context) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, string.format("%s=%s", tostring(key), to_text(context[key])))
	end

	if #parts == 0 then
		return ""
	end

	return " | " .. table.concat(parts, ", ")
end

local function log_path()
	local dir = vim.fn.stdpath("state")
	return dir .. "/" .. LOG_FILE_NAME
end

local function enforce_max_size(path)
	local max_bytes = 1024 * 1024
	if max_bytes <= 0 then
		return
	end

	local st = vim.uv.fs_stat(path)
	if not st or not st.size or st.size <= max_bytes then
		return
	end

	local lines = vim.fn.readfile(path)
	if #lines == 0 then
		return
	end

	-- Keep newest tail that fits max_bytes (approx by byte length of lines + newlines).
	local kept = {}
	local total = 0
	for i = #lines, 1, -1 do
		local line = lines[i]
		local cost = #line + 1
		if total + cost > max_bytes then
			break
		end
		table.insert(kept, 1, line)
		total = total + cost
	end

	vim.fn.writefile(kept, path)
end

---@param level AtlasLogLevel
---@param message any
---@param context table|nil
local function write(level, message, context)
	local line = string.format("%s [%s] %s%s", now_iso(), level, to_text(message), context_suffix(context))
	local path = log_path()

	local function do_write()
		enforce_max_size(path)
		vim.fn.writefile({ line }, path, "a")
	end

	if vim.in_fast_event() then
		vim.schedule(do_write)
		return
	end

	do_write()
end

---@param message any
---@param context table|nil
function M.logdebug(message, context)
	write("DEBUG", message, context)
end

---@param message any
---@param context table|nil
function M.loginfo(message, context)
	write("INFO", message, context)
end

---@param message any
---@param context table|nil
function M.logwarn(message, context)
	write("WARN", message, context)
end

---@param message any
---@param context table|nil
function M.logerror(message, context)
	write("ERROR", message, context)
end

---@param level AtlasLogLevel|nil
---@param message any
---@param context table|nil
function M.log(level, message, context)
	write(level or DEFAULT_LEVEL, message, context)
end

---@return string
function M.path()
	return log_path()
end

---@return string[]
function M.read_lines()
	local path = log_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	return vim.fn.readfile(path)
end

function M.clear()
	local path = log_path()
	if vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
	end
end

return M
