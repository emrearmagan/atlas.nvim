local M = {}

---@param level integer
---@param message any
---@param opts table|nil
function M.show(level, message, opts)
	vim.notify("[Atlas] " .. tostring(message), level, opts)
end

---@param message any
---@param opts table|nil
function M.info(message, opts)
	M.show(vim.log.levels.INFO, message, opts)
end

---@param message any
---@param opts table|nil
function M.warn(message, opts)
	M.show(vim.log.levels.WARN, message, opts)
end

---@param message any
---@param opts table|nil
function M.error(message, opts)
	M.show(vim.log.levels.ERROR, message, opts)
end

return M
