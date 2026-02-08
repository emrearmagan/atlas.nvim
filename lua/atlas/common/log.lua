---@class Common.Log
local M = {}

local log_file = vim.fn.stdpath("cache") .. "/atlas.log"
local max_log_size = 1024 * 1024 -- 1MB
local max_lines = 1000

---Truncate log if too large
local function truncate_log_if_needed()
  local stat = vim.loop.fs_stat(log_file)
  if stat and stat.size > max_log_size then
    local lines = vim.fn.readfile(log_file)
    if #lines > max_lines then
      local keep_lines = vim.list_slice(lines, #lines - max_lines + 1, #lines)
      vim.fn.writefile(keep_lines, log_file)
    end
  end
end

---Write log message to file
---@param module string Module name (e.g., "Bitbucket", "Jira")
---@param msg string Log message
local function write_log(module, msg)
  truncate_log_if_needed()
  local f = io.open(log_file, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. module .. "] " .. msg .. "\n")
    f:close()
  end
end

---Log Bitbucket message
---@param msg string
function M.bitbucket(msg)
  write_log("Bitbucket", msg)
end

---Log Jira message
---@param msg string
function M.jira(msg)
  write_log("Jira", msg)
end

---Get log file path
---@return string
function M.get_log_file()
  return log_file
end

return M
