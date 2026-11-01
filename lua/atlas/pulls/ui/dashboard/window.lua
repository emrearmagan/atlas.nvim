local M = {}

local config = require("atlas.config")
local events = require("atlas.core.events")
local resolver = require("atlas.core.keymaps")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

M.statusline = statusline.new({
	help_key = function()
		local keys = resolver.resolve("ui.help")
		return keys and keys[1]
	end,
	show_version = true,
})

---@type table<integer, table>
M.line_map = {}

local state = {
	win = nil,
	buf = nil,
	tab = nil,
	previous_win = nil,
	session_id = nil,
	group = nil,
	listed = false,
	options = nil,
	closing = false,
}

---@return integer|nil
local function window()
	return utils.window.valid(state.win) and state.win or nil
end

---@param win integer
---@param name string
---@param value boolean|string
local function set_option(win, name, value)
	vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

---@return integer|nil
function M.win()
	local win = window()
	if win == nil then
		return nil
	end
	if state.listed and vim.api.nvim_win_get_buf(win) ~= state.buf then
		return nil
	end
	return win
end

---@return integer|nil
function M.buf()
	return utils.buffer.valid(state.buf) and state.buf or nil
end

local function capture_options()
	local win = M.win()
	if win == nil then
		return
	end
	state.options = {}
	for _, name in ipairs({
		"number",
		"relativenumber",
		"signcolumn",
		"statuscolumn",
		"foldcolumn",
		"foldmethod",
		"foldenable",
		"wrap",
		"cursorline",
		"scrollbind",
		"cursorbind",
		"diff",
		"winbar",
		"statusline",
		"winhighlight",
	}) do
		state.options[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" })
	end
end

local function restore_options()
	local win = window()
	if win == nil or state.options == nil then
		return
	end
	statusline.detach(win)
	for name, value in pairs(state.options) do
		if name ~= "statusline" or statusline.enabled() then
			set_option(win, name, value)
		end
	end
	state.options = nil
end

local function configure_window()
	local win = M.win()
	if win == nil then
		return
	end
	for name, value in pairs({
		number = false,
		relativenumber = false,
		list = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldmethod = "manual",
		foldenable = false,
		wrap = false,
		cursorline = true,
		scrollbind = false,
		cursorbind = false,
		diff = false,
		winbar = "",
		winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine",
	}) do
		set_option(win, name, value)
	end
	M.statusline:attach(win)
end

---@param session_id string
---@param reason string
---@param close_tab boolean
local function close_session(session_id, reason, close_tab)
	if state.session_id ~= session_id or state.closing then
		return
	end
	state.closing = true

	local provider = require("atlas.pulls.state").provider
	local event = {
		version = 1,
		session_id = session_id,
		tabpage = state.tab,
		domain = "pulls",
		provider = provider and provider.id,
		reason = reason,
	}
	local tab = state.tab
	local group = state.group
	local previous_win = state.previous_win

	require("atlas.pulls.ui.detail.window").close(state.tab)
	require("atlas.pulls.ui.dashboard.controller").dispose()
	M.line_map = {}
	statusline.detach(state.win)
	if state.buf then
		require("atlas.pulls.ui.dashboard.keymaps").remove(state.buf)
	end
	if close_tab and utils.window.valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	if close_tab and tab and vim.api.nvim_tabpage_is_valid(tab) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
	end
	utils.buffer.delete(state.buf)
	if group then
		pcall(vim.api.nvim_del_augroup_by_id, group)
	end

	state.win = nil
	state.buf = nil
	state.tab = nil
	state.previous_win = nil
	state.session_id = nil
	state.group = nil
	state.listed = false
	state.options = nil
	state.closing = false
	M.statusline:reset()
	if close_tab and utils.window.valid(previous_win) then
		vim.api.nvim_set_current_win(previous_win)
	end
	events.emit("AtlasUIClosed", event)
end

---@param session_id string
local function setup_listed_buffer(session_id)
	capture_options()
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = state.group,
		buffer = state.buf,
		callback = function()
			if state.session_id == session_id and not state.closing and vim.api.nvim_get_current_win() == state.win then
				require("atlas.pulls.ui.detail.window").close(state.tab)
				restore_options()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = state.group,
		buffer = state.buf,
		callback = function()
			if state.session_id == session_id and not state.closing and vim.api.nvim_get_current_win() == state.win then
				capture_options()
				configure_window()
				M.render()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufDelete", {
		group = state.group,
		buffer = state.buf,
		once = true,
		callback = function()
			vim.schedule(function()
				close_session(session_id, "buffer_deleted", false)
			end)
		end,
	})
end

local function create()
	state.previous_win = vim.api.nvim_get_current_win()
	state.buf = utils.buffer.create("Atlas Pulls", "atlas-ui.dashboard")
	state.listed = config.options.ui.listed_buffer == true
	vim.api.nvim_set_option_value("buflisted", state.listed, { buf = state.buf })
	vim.cmd("tabnew")
	local tab = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	state.tab = tab
	state.win = win
	local placeholder = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_buf(state.win, state.buf)
	if placeholder ~= state.buf and utils.buffer.valid(placeholder) then
		pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
	end

	local session_id = events.new_id("ui")
	state.session_id = session_id
	state.group = vim.api.nvim_create_augroup("AtlasPullsDashboard" .. session_id, { clear = true })
	state.closing = false
	if state.listed then
		setup_listed_buffer(session_id)
	end
	configure_window()

	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		pattern = tostring(win),
		once = true,
		callback = function()
			vim.schedule(function()
				local reason = vim.api.nvim_tabpage_is_valid(tab) and "window_closed" or "tab_closed"
				close_session(session_id, reason, true)
			end)
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = state.group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(tab) then
				vim.schedule(function()
					close_session(session_id, "tab_closed", true)
				end)
			end
		end,
	})
end

function M.open()
	if window() == nil or M.buf() == nil then
		if state.session_id then
			close_session(state.session_id, "replaced", true)
		end
		create()
	else
		require("atlas.pulls.ui.detail.window").close(state.tab)
		require("atlas.pulls.ui.dashboard.controller").dispose()
	end

	if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
		vim.api.nvim_set_current_tabpage(state.tab)
	end
	if state.listed and window() and M.buf() then
		vim.api.nvim_set_current_win(state.win)
		vim.api.nvim_win_set_buf(state.win, state.buf)
	end
	configure_window()
end

function M.render()
	if M.is_active() then
		require("atlas.pulls.ui.dashboard").render()
	end
end

---@return boolean
function M.is_active()
	return M.win() ~= nil and vim.api.nvim_get_current_tabpage() == state.tab
end

---@param reason string|nil
function M.close(reason)
	if state.session_id then
		close_session(state.session_id, reason or "user_close", true)
	end
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "TabEnter" }, {
	group = vim.api.nvim_create_augroup("AtlasPullsDashboardResize", { clear = true }),
	callback = function()
		if M.is_active() then
			require("atlas.pulls.ui.dashboard").resize()
		end
	end,
})

return M
