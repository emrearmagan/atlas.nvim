local M = {}

local config = require("atlas.config")
local events = require("atlas.core.events")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local state = {
	win = nil,
	buf = nil,
	tab = nil,
	previous_win = nil,
	session_id = nil,
	group = nil,
	domain = nil,
	provider = nil,
	listed = false,
	options = nil,
	closing = false,
}

local resize_group = vim.api.nvim_create_augroup("AtlasDashboardResize", { clear = true })

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
	statusline.attach(win)
end

local function dispose_domain()
	local domain = state.domain
	state.domain = nil
	state.provider = nil
	if domain then
		local module = require("atlas." .. domain)
		pcall(module.dispose)
	end
end

local function reset_ui_state()
	local ui_state = require("atlas.ui.state")
	ui_state.domain = nil
	ui_state.line_map = {}
end

local function close_detail()
	require("atlas.ui.detail").close(state.tab)
end

---@param session_id string
---@param reason string
---@param close_tab boolean
local function close_session(session_id, reason, close_tab)
	if state.session_id ~= session_id or state.closing then
		return
	end
	state.closing = true

	local event = {
		version = 1,
		session_id = session_id,
		tabpage = state.tab,
		domain = state.domain,
		provider = state.provider,
		reason = reason,
	}
	local tab = state.tab
	local group = state.group
	local previous_win = state.previous_win

	close_detail()
	dispose_domain()
	reset_ui_state()
	if state.buf and utils.buffer.valid(state.buf) then
		require("atlas.ui.keymaps").remove(state.buf)
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
	statusline.reset()
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
				close_detail()
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
	state.buf = utils.buffer.create("Atlas", "atlas")
	state.listed = config.options.ui.listed_buffer == true
	vim.api.nvim_set_option_value("buflisted", state.listed, { buf = state.buf })
	vim.cmd("tabnew")
	state.tab = vim.api.nvim_get_current_tabpage()
	state.win = vim.api.nvim_get_current_win()
	local placeholder = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_buf(state.win, state.buf)
	if placeholder ~= state.buf and utils.buffer.valid(placeholder) then
		pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
	end

	state.session_id = events.new_id("ui")
	state.group = vim.api.nvim_create_augroup("AtlasDashboard" .. state.session_id, { clear = true })
	state.closing = false
	if state.listed then
		setup_listed_buffer(state.session_id)
	end
	configure_window()

	local session_id = state.session_id
	local tab = state.tab
	local win = state.win
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

---@param domain AtlasDomain
---@param provider AtlasProviderId
function M.open(domain, provider)
	if window() == nil or M.buf() == nil then
		if state.session_id then
			close_session(state.session_id, "replaced", true)
		end
		create()
	elseif state.domain then
		close_detail()
		dispose_domain()
	end

	state.domain = domain
	state.provider = provider
	require("atlas.ui.state").domain = domain
	if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
		vim.api.nvim_set_current_tabpage(state.tab)
	end
	if state.listed and window() and M.buf() then
		vim.api.nvim_set_current_win(state.win)
		vim.api.nvim_win_set_buf(state.win, state.buf)
	end
	require("atlas.ui.keymaps").register(state.buf)
end

function M.render()
	if M.is_active() and state.domain then
		require("atlas." .. state.domain).render()
	end
end

function M.is_open()
	return window() ~= nil
end

---@param domain AtlasDomain|nil
---@param provider AtlasProviderId|nil
function M.is_active(domain, provider)
	return M.win() ~= nil
		and vim.api.nvim_get_current_tabpage() == state.tab
		and (domain == nil or state.domain == domain)
		and (provider == nil or state.provider == provider)
end

---@param reason string|nil
function M.close(reason)
	if state.session_id then
		close_session(state.session_id, reason or "user_close", true)
	end
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "TabEnter" }, {
	group = resize_group,
	callback = M.render,
})

return M
