local M = {}

local keymaps = require("atlas.core.keymaps")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_loading")

---@class AtlasLoadingView
---@field update fun(self: AtlasLoadingView, message: string)
---@field finish fun(self: AtlasLoadingView)
---@field cancel fun(self: AtlasLoadingView)

---@param view table
---@param text string
local function render(view, text)
	if not vim.api.nvim_win_is_valid(view.win) or not vim.api.nvim_buf_is_valid(view.buf) then
		return
	end

	local height = vim.api.nvim_win_get_height(view.win)
	if vim.api.nvim_buf_line_count(view.buf) ~= height then
		local lines = {}
		for _ = 1, height do
			lines[#lines + 1] = ""
		end
		vim.bo[view.buf].modifiable = true
		vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
		vim.bo[view.buf].modifiable = false
	end

	local width = vim.api.nvim_win_get_width(view.win)
	local row = math.floor((height - 1) / 2)
	vim.api.nvim_buf_clear_namespace(view.buf, namespace, 0, -1)
	for index, line in ipairs(vim.split(text:gsub("\r", ""), "\n", { plain = true })) do
		if row + index > height then
			break
		end
		line = utils.truncate(line, math.max(1, width - 4))
		vim.api.nvim_buf_set_extmark(view.buf, namespace, row + index - 1, 0, {
			virt_text = { { line, "Normal" } },
			virt_text_win_col = math.max(0, math.floor((width - vim.fn.strdisplaywidth(line)) / 2)),
		})
	end
end

---@param message string
---@param on_cancel fun()|nil
---@return AtlasLoadingView
function M.open(message, on_cancel)
	vim.cmd("tabnew")
	local view = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		win = vim.api.nvim_get_current_win(),
		buf = vim.api.nvim_get_current_buf(),
	}
	vim.bo[view.buf].bufhidden = "wipe"
	vim.bo[view.buf].buflisted = false
	vim.bo[view.buf].buftype = "nofile"
	vim.bo[view.buf].filetype = "atlas.loading"
	vim.bo[view.buf].syntax = "OFF"
	vim.bo[view.buf].swapfile = false
	vim.bo[view.buf].undolevels = -1
	pcall(vim.treesitter.stop, view.buf)
	for name, value in pairs({
		cursorline = false,
		diff = false,
		foldcolumn = "0",
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		winbar = " ",
		wrap = false,
	}) do
		vim.api.nvim_set_option_value(name, value, { win = view.win, scope = "local" })
	end

	local active = true
	local text = message
	local group = vim.api.nvim_create_augroup("AtlasLoading" .. view.tabpage, { clear = true })
	local indicator

	local function draw()
		if active then
			render(view, indicator:text(text))
		end
	end

	local function stop()
		if not active then
			return false
		end
		active = false
		indicator:stop()
		pcall(vim.api.nvim_del_augroup_by_id, group)
		return true
	end

	local function close(cancelled)
		if not stop() then
			return
		end
		if vim.api.nvim_tabpage_is_valid(view.tabpage) then
			pcall(vim.cmd, vim.api.nvim_tabpage_get_number(view.tabpage) .. "tabclose")
		end
		if cancelled and on_cancel then
			on_cancel()
		end
	end

	view.update = function(_, next_message)
		text = next_message
		draw()
	end
	view.finish = function()
		close(false)
	end
	view.cancel = function()
		close(true)
	end
	---@cast view AtlasLoadingView

	indicator = spinner.create({ on_tick = draw })
	for _, key in ipairs(keymaps.resolve("ui.close") or {}) do
		vim.keymap.set("n", key, view.cancel, { buffer = view.buf, silent = true, nowait = true, desc = "Cancel" })
	end
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group,
		callback = draw,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				view:cancel()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = view.buf,
		callback = function()
			vim.schedule(view.cancel)
		end,
	})
	indicator:start()
	draw()
	return view
end

return M
