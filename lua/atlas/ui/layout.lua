local M = {}

local footer = require("atlas.ui.components.footer")
local buf_util = require("atlas.ui.shared.buffer")
local win_util = require("atlas.ui.shared.window")

local state = {
	main_win = nil,
	main_buf = nil,
	tab_id = nil,
	prev_win = nil,
	footer_win = nil,
	footer_buf = nil,
	detail_win = nil,
	detail_buf = nil,
	render_callback = nil,
}

local resize_group = vim.api.nvim_create_augroup("AtlasUILayoutResize", { clear = true })

local function ensure_buf(buf_field, name, filetype)
	local existing = state[buf_field]
	if existing and buf_util.valid(existing) then
		return existing
	end
	local buf = buf_util.create(name, filetype)
	state[buf_field] = buf
	return buf
end

local function ensure_main()
	if win_util.valid(state.main_win) and buf_util.valid(state.main_buf) then
		return
	end
	state.prev_win = vim.api.nvim_get_current_win()
	local main_buf = ensure_buf("main_buf", "Atlas", "atlas")
	vim.cmd("tabnew")
	state.tab_id = vim.api.nvim_get_current_tabpage()
	state.main_win = vim.api.nvim_get_current_win()
	local tab_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_buf(state.main_win, main_buf)
	if tab_buf ~= main_buf and buf_util.valid(tab_buf) then
		pcall(vim.api.nvim_buf_delete, tab_buf, { force = true })
	end
	win_util.apply_main_opts(state.main_win)

	vim.api.nvim_create_autocmd("WinClosed", {
		group = resize_group,
		pattern = tostring(state.main_win),
		once = true,
		callback = function()
			vim.schedule(function()
				M.close()
			end)
		end,
	})
end

local function ensure_footer()
	if not win_util.valid(state.main_win) then
		return
	end
	local buf = ensure_buf("footer_buf", "AtlasFooter", "atlas-footer")
	if win_util.valid(state.footer_win) then
		vim.api.nvim_win_set_buf(state.footer_win, buf)
	else
		state.footer_win = win_util.create(state.main_win, "botright split", buf, win_util.apply_footer_opts)
	end
	pcall(vim.api.nvim_win_set_height, state.footer_win, 1)
	local logs_win = require("atlas.ui.logs").win_id()
	if logs_win == nil then
		pcall(function()
			vim.api.nvim_win_call(state.footer_win, function()
				vim.cmd("wincmd J")
			end)
		end)
	else
		pcall(function()
			vim.api.nvim_win_call(logs_win, function()
				vim.cmd("wincmd J")
			end)
		end)
	end
end

function M.set_render_callback(fn)
	state.render_callback = fn
end

function M.is_open()
	return win_util.valid(state.main_win)
end

---@param pane "main"|"footer"|"detail"
---@return integer|nil
function M.win_id(pane)
	local key = pane .. "_win"
	if win_util.valid(state[key]) then
		return state[key]
	end
	return nil
end

---@param pane "main"|"footer"|"detail"
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
		vim.api.nvim_win_close(state.detail_win, true)
		state.detail_win = nil
		return
	end
	state.detail_buf = ensure_buf("detail_buf", "AtlasDetail", "")
	state.detail_win =
		win_util.create(state.main_win, "rightbelow vsplit", state.detail_buf, win_util.apply_detail_opts)
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
	ensure_footer()
	if win_util.valid(state.detail_win) then
		pcall(vim.api.nvim_win_set_width, state.detail_win, math.max(math.floor(vim.o.columns * 0.45), 40))
	end
	footer.refresh()
end

function M.open()
	M.ensure_open()
	footer.refresh()
end

function M.ensure_open()
	ensure_main()
	ensure_footer()
	local keymaps = require("atlas.ui.keymaps")
	if state.main_buf ~= nil and buf_util.valid(state.main_buf) then
		keymaps.register(state.main_buf)
	end
end

function M.close()
	if win_util.valid(state.detail_win) then
		vim.api.nvim_win_close(state.detail_win, true)
	end
	if win_util.valid(state.footer_win) then
		vim.api.nvim_win_close(state.footer_win, true)
	end
	state.detail_win = nil
	state.footer_win = nil
	if win_util.valid(state.main_win) then
		local keymaps = require("atlas.ui.keymaps")
		if state.main_buf ~= nil and buf_util.valid(state.main_buf) then
			keymaps.remove(state.main_buf)
		end
		vim.api.nvim_win_close(state.main_win, true)
	end
	if state.tab_id ~= nil and vim.api.nvim_tabpage_is_valid(state.tab_id) then
		local current_tab = vim.api.nvim_get_current_tabpage()
		if current_tab ~= state.tab_id then
			vim.api.nvim_set_current_tabpage(state.tab_id)
		end
		pcall(vim.cmd, "tabclose")
	end
	buf_util.delete(state.detail_buf)
	buf_util.delete(state.footer_buf)
	buf_util.delete(state.main_buf)
	state.main_win = nil
	state.main_buf = nil
	state.tab_id = nil
	state.detail_buf = nil
	state.footer_buf = nil
	if win_util.valid(state.prev_win) then
		vim.api.nvim_set_current_win(state.prev_win)
	end
	state.prev_win = nil
	state.render_callback = nil
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
		if type(state.render_callback) == "function" then
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
		if type(state.render_callback) == "function" then
			state.render_callback()
		end
	end,
})

return M
