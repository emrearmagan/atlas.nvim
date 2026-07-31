local M = {}

---@param win integer
---@param name string
---@param value boolean|string
local function set_option(win, name, value)
	vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

---@param win integer|nil
---@return boolean
function M.valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param anchor integer
---@param split_cmd string
---@param buf integer
---@param apply_opts fun(win: integer)
---@return integer
function M.create(anchor, split_cmd, buf, apply_opts)
	local prev = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(anchor)
	vim.cmd(split_cmd)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	apply_opts(win)
	if M.valid(prev) then
		vim.api.nvim_set_current_win(prev)
	end
	return win
end

---@param win integer
function M.apply_main_opts(win)
	set_option(win, "number", false)
	set_option(win, "relativenumber", false)
	set_option(win, "signcolumn", "no")
	set_option(win, "statuscolumn", "")
	set_option(win, "foldcolumn", "0")
	set_option(win, "wrap", false)
	set_option(win, "cursorline", true)
	set_option(win, "scrollbind", false)
	set_option(win, "cursorbind", false)
	set_option(win, "diff", false)
	set_option(win, "winbar", " ")
	set_option(win, "statusline", " ")
	set_option(win, "winhighlight", "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine")
end

---@param win integer
function M.apply_footer_opts(win)
	set_option(win, "number", false)
	set_option(win, "relativenumber", false)
	set_option(win, "signcolumn", "no")
	set_option(win, "statuscolumn", "")
	set_option(win, "foldcolumn", "0")
	set_option(win, "wrap", false)
	set_option(win, "cursorline", false)
	set_option(win, "winbar", " ")
	set_option(win, "statusline", " ")
	set_option(win, "winfixheight", true)
end

---@param win integer
function M.apply_detail_opts(win)
	set_option(win, "number", false)
	set_option(win, "relativenumber", false)
	set_option(win, "signcolumn", "no")
	set_option(win, "statuscolumn", "")
	set_option(win, "foldcolumn", "0")
	set_option(win, "wrap", true)
	set_option(win, "breakindent", true)
	set_option(win, "cursorline", true)
	set_option(win, "scrollbind", false)
	set_option(win, "cursorbind", false)
	set_option(win, "diff", false)
	set_option(win, "winbar", " ")
	set_option(win, "statusline", " ")
	set_option(win, "winfixwidth", false)
end

return M
