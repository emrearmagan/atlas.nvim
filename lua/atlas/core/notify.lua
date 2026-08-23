local M = {}

---@alias AtlasNotifyLevel "loading"|"success"|"info"|"warn"|"error"

---@class AtlasNotifyOptions
---@field timeout integer|nil
---@field vim_notify boolean|nil

---@param level AtlasNotifyLevel
---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.show(level, message, opts)
	opts = opts or {}
	message = tostring(message)

	local statusline = require("atlas.ui.statusline")
	local attached = statusline.is_attached()
	if attached then
		statusline.notify(level, message, opts.timeout)
	end

	if not attached or opts.vim_notify then
		local native_level = vim.log.levels[level:upper()] or vim.log.levels.INFO
		vim.notify("[Atlas] " .. message, native_level, opts.timeout and { timeout = opts.timeout } or nil)
	end
end

---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.info(message, opts)
	M.show("info", message, opts)
end

---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.success(message, opts)
	M.show("success", message, opts)
end

---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.warn(message, opts)
	M.show("warn", message, opts)
end

---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.error(message, opts)
	M.show("error", message, opts)
end

---@param message any
---@param opts AtlasNotifyOptions|table|nil
function M.loading(message, opts)
	M.show("loading", message, opts)
end

function M.clear()
	require("atlas.ui.statusline").clear_notice()
end

return M
