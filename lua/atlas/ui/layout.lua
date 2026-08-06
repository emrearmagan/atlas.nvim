local M = {}

local events = require("atlas.core.events")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")
local buf_util = utils.buffer
local win_util = utils.window

local state = {
	main_win = nil,
	main_buf = nil,
	tab_id = nil,
	prev_win = nil,
	detail_win = nil,
	detail_buf = nil,
	render_callback = nil,
	session_id = nil,
	autocmd_group = nil,
	cleanup = nil,
	closing = false,
	domain = nil,
	provider = nil,
}

local resize_group = vim.api.nvim_create_augroup("AtlasUILayoutResize", { clear = true })

---@param win integer
---@param name string
---@param value boolean|string
local function set_window_option(win, name, value)
	vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

---@param win integer
local function apply_main_opts(win)
	set_window_option(win, "number", false)
	set_window_option(win, "relativenumber", false)
	set_window_option(win, "signcolumn", "no")
	set_window_option(win, "statuscolumn", "")
	set_window_option(win, "foldcolumn", "0")
	set_window_option(win, "wrap", false)
	set_window_option(win, "cursorline", true)
	set_window_option(win, "scrollbind", false)
	set_window_option(win, "cursorbind", false)
	set_window_option(win, "diff", false)
	set_window_option(win, "winbar", " ")
	statusline.attach(win)
	set_window_option(
		win,
		"winhighlight",
		"Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine"
	)
end

---@param win integer
local function apply_detail_opts(win)
	set_window_option(win, "number", false)
	set_window_option(win, "relativenumber", false)
	set_window_option(win, "signcolumn", "no")
	set_window_option(win, "statuscolumn", "")
	set_window_option(win, "foldcolumn", "0")
	set_window_option(win, "wrap", true)
	set_window_option(win, "breakindent", true)
	set_window_option(win, "cursorline", true)
	set_window_option(win, "scrollbind", false)
	set_window_option(win, "cursorbind", false)
	set_window_option(win, "diff", false)
	set_window_option(win, "winbar", " ")
	statusline.attach(win)
	set_window_option(win, "winfixwidth", false)
end

local function ensure_buf(buf_field, name, filetype)
	local existing = state[buf_field]
	if existing and buf_util.valid(existing) then
		return existing
	end
	local buf = buf_util.create(name, filetype)
	state[buf_field] = buf
	return buf
end

---@param session_id string
---@param win integer
---@param close_window boolean
---@param cleanup_panel boolean
local function close_detail(session_id, win, close_window, cleanup_panel)
	if state.session_id ~= session_id or state.detail_win ~= win then
		return
	end
	if close_window and win_util.valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	state.detail_win = nil
	if cleanup_panel then
		local on_close = require("atlas.ui.state").on_panel_close
		if on_close then
			pcall(on_close)
		end
	end
end

---@param session_id string
---@param reason string
local function close_session(session_id, reason)
	if state.session_id ~= session_id or state.closing then
		return
	end
	state.closing = true

	local data = {
		version = 1,
		session_id = session_id,
		tabpage = state.tab_id,
		domain = state.domain,
		provider = state.provider,
		reason = reason,
	}
	local tabpage = state.tab_id
	local autocmd_group = state.autocmd_group
	if state.cleanup then
		pcall(state.cleanup)
		state.cleanup = nil
	end

	local ui_state = require("atlas.ui.state")
	ui_state.current_view = ""
	ui_state.line_map = {}
	ui_state.on_select = nil
	ui_state.on_panel_open = nil
	ui_state.on_panel_close = nil
	ui_state.on_panel_next_tab = nil
	ui_state.on_panel_prev_tab = nil

	if state.detail_win then
		close_detail(session_id, state.detail_win, true, false)
	end
	if state.main_buf and buf_util.valid(state.main_buf) then
		require("atlas.ui.keymaps").remove(state.main_buf)
	end
	if win_util.valid(state.main_win) then
		vim.api.nvim_win_close(state.main_win, true)
	end
	if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tabpage) .. "tabclose")
	end
	buf_util.delete(state.detail_buf)
	buf_util.delete(state.main_buf)
	if autocmd_group then
		pcall(vim.api.nvim_del_augroup_by_id, autocmd_group)
	end

	state.main_win = nil
	state.main_buf = nil
	state.tab_id = nil
	state.detail_win = nil
	state.detail_buf = nil
	state.render_callback = nil
	state.session_id = nil
	state.autocmd_group = nil
	state.cleanup = nil
	state.domain = nil
	state.provider = nil
	state.closing = false
	statusline.reset()
	if win_util.valid(state.prev_win) then
		vim.api.nvim_set_current_win(state.prev_win)
	end
	state.prev_win = nil

	events.emit("AtlasUIClosed", data)
end

local function ensure_main()
	if win_util.valid(state.main_win) and buf_util.valid(state.main_buf) then
		return
	end
	if state.session_id then
		close_session(state.session_id, "replaced")
	end
	state.prev_win = vim.api.nvim_get_current_win()
	local main_buf = ensure_buf("main_buf", "Atlas", "atlas")
	vim.cmd("tabnew")
	state.tab_id = vim.api.nvim_get_current_tabpage()
	local session_id = events.new_id("ui")
	local tabpage = state.tab_id
	state.session_id = session_id
	state.autocmd_group = vim.api.nvim_create_augroup("AtlasUILayout" .. session_id, { clear = true })
	state.closing = false
	state.main_win = vim.api.nvim_get_current_win()
	local tab_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_buf(state.main_win, main_buf)
	if tab_buf ~= main_buf and buf_util.valid(tab_buf) then
		pcall(vim.api.nvim_buf_delete, tab_buf, { force = true })
	end
	apply_main_opts(state.main_win)

	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.autocmd_group,
		pattern = tostring(state.main_win),
		once = true,
		callback = function()
			vim.schedule(function()
				local reason = vim.api.nvim_tabpage_is_valid(tabpage) and "window_closed" or "tab_closed"
				close_session(session_id, reason)
			end)
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = state.autocmd_group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(tabpage) then
				vim.schedule(function()
					close_session(session_id, "tab_closed")
				end)
			end
		end,
	})
end

---@param fn fun()|nil
function M.set_render_callback(fn)
	state.render_callback = fn
end

---@param cleanup fun()
---@param data { domain: "pulls"|"issues", provider: string }
function M.set_context(cleanup, data)
	if not state.session_id or state.closing then
		return
	end
	if state.cleanup then
		pcall(state.cleanup)
		state.cleanup = nil
		if state.detail_win then
			close_detail(state.session_id, state.detail_win, true, false)
		end
	end
	state.cleanup = cleanup
	state.domain = data.domain
	state.provider = data.provider
end

function M.is_open()
	return win_util.valid(state.main_win)
end

---@param pane "main"|"detail"
---@return integer|nil
function M.win_id(pane)
	local key = pane .. "_win"
	if win_util.valid(state[key]) then
		return state[key]
	end
	return nil
end

---@param pane "main"|"detail"
---@return integer|nil
function M.buf_id(pane)
	local key = pane .. "_buf"
	if buf_util.valid(state[key]) then
		return state[key]
	end
	return nil
end

function M.toggle_detail()
	if not win_util.valid(state.main_win) then
		return
	end
	if win_util.valid(state.detail_win) then
		close_detail(state.session_id, state.detail_win, true, true)
		return
	end
	state.detail_buf = ensure_buf("detail_buf", "AtlasDetail", "atlas-detail")
	state.detail_win = win_util.create(state.main_win, "rightbelow vsplit", state.detail_buf, apply_detail_opts)
	local detail_win = state.detail_win
	local session_id = state.session_id
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.autocmd_group,
		pattern = tostring(detail_win),
		once = true,
		callback = function()
			vim.schedule(function()
				close_detail(session_id, detail_win, false, true)
			end)
		end,
	})
	pcall(vim.api.nvim_win_set_width, state.detail_win, math.max(math.floor(vim.o.columns * 0.45), 40))

	if win_util.valid(state.main_win) then
		vim.api.nvim_win_call(state.main_win, function()
			vim.cmd("normal! 0")
		end)
	end
end

function M.reflow()
	if not M.is_open() then
		return
	end
	if win_util.valid(state.detail_win) then
		pcall(vim.api.nvim_win_set_width, state.detail_win, math.max(math.floor(vim.o.columns * 0.45), 40))
	end
end

function M.ensure_open()
	ensure_main()
	local keymaps = require("atlas.ui.keymaps")
	if state.main_buf ~= nil and buf_util.valid(state.main_buf) then
		keymaps.register(state.main_buf)
	end
end

---@param reason string|nil
function M.close(reason)
	if state.session_id then
		close_session(state.session_id, reason or "user_close")
	end
end

--- When scrolling in the panel or notification window the main view kinda break and this helps. I dont know why tho..
vim.api.nvim_create_autocmd("WinScrolled", {
	group = resize_group,
	callback = function()
		if not M.is_open() then
			return
		end

		local main_key = tostring(state.main_win or "")
		for win_key, _ in pairs(vim.v.event) do
			if win_key ~= "all" and win_key ~= main_key then
				vim.cmd("redraw!")
				return
			end
		end
	end,
})

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
	group = resize_group,
	callback = function()
		if not M.is_open() then
			return
		end
		M.reflow()
		if state.render_callback then
			state.render_callback()
		end
	end,
})

vim.api.nvim_create_autocmd("TabEnter", {
	group = resize_group,
	callback = function()
		if not M.is_open() then
			return
		end
		if vim.api.nvim_get_current_tabpage() ~= state.tab_id then
			return
		end
		M.reflow()
		if state.render_callback then
			state.render_callback()
		end
	end,
})

return M
