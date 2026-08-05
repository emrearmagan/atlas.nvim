local M = {}

local next_id = 0

---@param prefix string
---@return string
function M.new_id(prefix)
	next_id = next_id + 1
	return string.format("%s:%d", prefix, next_id)
end

---@param name string
---@param data table
function M.emit(name, data)
	pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = name,
		data = data,
		modeline = false,
	})
end

return M
