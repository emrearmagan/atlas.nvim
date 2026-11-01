local M = {}

local utils = require("atlas.ui.shared.utils")
local dashboard_window = require("atlas.issues.ui.dashboard.window")

local state = {
	win = nil,
	buf = nil,
	cleanup = nil,
	render = nil,
}

---@param win integer
local function configure(win)
	for name, value in pairs({
		number = false,
		relativenumber = false,
		list = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldmethod = "manual",
		foldenable = false,
		wrap = true,
		linebreak = true,
		breakindent = false,
		cursorline = true,
		scrollbind = false,
		cursorbind = false,
		diff = false,
		winbar = "",
		winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine",
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
	dashboard_window.statusline:attach(win)
end

local function deactivate()
	local cleanup = state.cleanup
	state.cleanup = nil
	state.render = nil
	if cleanup then
		cleanup()
	end
end

local function create()
	local from_dashboard = vim.api.nvim_get_current_win() == dashboard_window.win()
	-- one panel per tab.. if the PR panel is open here, this one replaces it. Mostly because its currently a single state
	require("atlas.pulls.ui.detail.window").close(vim.api.nvim_get_current_tabpage())
	local beside_dashboard = dashboard_window.is_active()
	local source = beside_dashboard and dashboard_window.win() or vim.api.nvim_get_current_win()
	local buf = utils.buffer.create("atlas://issues/detail", "atlas-ui.detail")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	local win = utils.window.create(source, "botright vsplit", buf, configure)
	pcall(vim.api.nvim_win_set_width, win, math.max(math.floor(vim.o.columns * 0.45), 40))
	if not from_dashboard then
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
				dashboard_window.render()
			end
		end,
	})
end

---@param cleanup fun()
---@param render fun()
---@return integer win, integer buf
function M.open(cleanup, render)
	-- there's only one issue panel.. if it's open in another tab, it moves over here. Mostly because its currently a single state
	if M.is_open() and vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage() then
		M.close()
	end
	if not M.is_open() then
		deactivate()
		state.win = nil
		state.buf = nil
		create()
	end

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

---@param direction "up"|"down"
---@param is_selectable fun(lnum: integer): boolean
function M.move_cursor(direction, is_selectable)
	local win = state.win
	local buf = state.buf
	if not utils.window.valid(win) or not utils.buffer.valid(buf) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]
	local col = cursor[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local bound = direction == "up" and 1 or max_line

	if is_selectable(line) then
		for lnum = line + step, bound, step do
			if is_selectable(lnum) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				return
			end
		end
	end

	local next_line = line + step
	if next_line >= 1 and next_line <= max_line then
		vim.api.nvim_win_set_cursor(win, { next_line, col })
	end
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
	dashboard_window.render()
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
	group = vim.api.nvim_create_augroup("AtlasIssuesDetailResize", { clear = true }),
	callback = function(event)
		if not M.is_open() then
			return
		end

		if event.event == "VimResized" then
			pcall(vim.api.nvim_win_set_width, state.win, math.max(math.floor(vim.o.columns * 0.45), 40))
		elseif not vim.tbl_contains(vim.v.event.windows, state.win) then
			return
		end

		if state.render then
			state.render()
		end
	end,
})

return M
