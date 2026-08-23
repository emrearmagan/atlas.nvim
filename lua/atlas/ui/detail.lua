local M = {}

local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local state = {
	view = nil,
	win = nil,
	buf = nil,
	cleanup = nil,
	render = nil,
}

local function configure(win)
	for name, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldmethod = "manual",
		foldenable = false,
		wrap = true,
		breakindent = true,
		cursorline = true,
		scrollbind = false,
		cursorbind = false,
		diff = false,
		winbar = "",
		winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine",
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
	statusline.attach(win)
end

local function reset_content()
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
		vim.api.nvim_buf_clear_namespace(state.buf, -1, 0, -1)
		vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
		vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	end
	if utils.window.valid(state.win) then
		vim.api.nvim_set_option_value("winbar", "", { win = state.win, scope = "local" })
	end
end

local function deactivate()
	local cleanup = state.cleanup
	state.view = nil
	state.cleanup = nil
	state.render = nil
	if cleanup then
		cleanup()
	end
end

local function render_dashboard()
	require("atlas.ui.dashboard").render()
end

local function create()
	local dashboard = require("atlas.ui.dashboard")
	local beside_dashboard = dashboard.is_active()
	local source = beside_dashboard and dashboard.win() or vim.api.nvim_get_current_win()
	local buf = utils.buffer.create("atlas://detail", "atlas.detail")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	local win = utils.window.create(source, "rightbelow vsplit", buf, configure)
	pcall(vim.api.nvim_win_set_width, win, math.max(math.floor(vim.o.columns * 0.45), 40))
	if not beside_dashboard then
		vim.api.nvim_set_current_win(win)
	end

	state.win = win
	state.buf = buf
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if state.win == win then
				deactivate()
				state.win = nil
				state.buf = nil
				render_dashboard()
			end
		end,
	})
end

---@param view "issues"|"pulls"|"repo"
---@param cleanup fun()
---@param render fun()
---@return integer win, integer buf
function M.open(view, cleanup, render)
	require("atlas.ui.shared.highlights").setup()
	if M.is_open() and vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage() then
		M.close()
	end
	if not M.is_open() then
		deactivate()
		state.win = nil
		state.buf = nil
		create()
	elseif state.view ~= view then
		deactivate()
		reset_content()
	end

	state.view = view
	state.cleanup = cleanup
	state.render = render
	return state.win, state.buf
end

---@param tab integer|nil
---@return boolean
function M.is_open(tab)
	return utils.window.valid(state.win)
		and utils.buffer.valid(state.buf)
		and state.render ~= nil
		and (tab == nil or vim.api.nvim_win_get_tabpage(state.win) == tab)
end

---@param view "issues"|"pulls"|"repo"
---@param tab integer|nil
---@return boolean
function M.is_showing(view, tab)
	return M.is_open(tab) and state.view == view
end

---@param tab integer|nil
function M.close(tab)
	if not M.is_open(tab) then
		return
	end

	local win = state.win
	local buf = state.buf
	deactivate()
	state.win = nil
	state.buf = nil
	if utils.window.valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	utils.buffer.delete(buf)
	render_dashboard()
end

vim.api.nvim_create_autocmd("VimResized", {
	group = vim.api.nvim_create_augroup("AtlasDetailResize", { clear = true }),
	callback = function()
		if not M.is_open() then
			return
		end
		pcall(vim.api.nvim_win_set_width, state.win, math.max(math.floor(vim.o.columns * 0.45), 40))
		if state.render then
			state.render()
		end
	end,
})

return M
