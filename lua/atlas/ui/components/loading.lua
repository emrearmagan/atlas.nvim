local M = {}

local namespace = vim.api.nvim_create_namespace("atlas_loading")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

---@param buf integer
function M.clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	end
end

---@param buf integer
---@param win integer|nil
---@param text string
---@param hl_group string|nil
function M.render(buf, win, text, hl_group)
	if not win or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local height = math.max(1, vim.api.nvim_win_get_height(win))
	local reset_lines = vim.api.nvim_buf_line_count(buf) ~= height
	if reset_lines then
		local lines = {}
		for _ = 1, height do
			table.insert(lines, "")
		end
		local modifiable = vim.bo[buf].modifiable
		local readonly = vim.bo[buf].readonly
		vim.bo[buf].readonly = false
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false
		vim.bo[buf].modifiable = modifiable
		vim.bo[buf].readonly = readonly
	end
	local width = vim.api.nvim_win_get_width(win)
	text = utils.truncate(tostring(text):gsub("[\r\n]+", " | "), math.max(1, width - 4))
	local col = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
	M.clear(buf)
	vim.api.nvim_buf_set_extmark(buf, namespace, math.floor((height - 1) / 2), 0, {
		virt_text = { { text, hl_group or "AtlasLogInfo" } },
		virt_text_win_col = col,
	})
end

---@class AtlasLoadingView
---@field tabpage integer
---@field buf integer
---@field win integer
---@field message string
---@field closed boolean
---@field update fun(self: AtlasLoadingView, message: string)
---@field finish fun(self: AtlasLoadingView)
---@field cancel fun(self: AtlasLoadingView)

---@param message string
---@param on_cancel fun()|nil
---@return AtlasLoadingView
function M.open(message, on_cancel)
	vim.cmd("tabnew")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "atlas-loading"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	for name, value in pairs({
		cursorline = false,
		diff = false,
		foldcolumn = "0",
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		statusline = " ",
		winbar = " ",
		wrap = false,
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end

	local group = vim.api.nvim_create_augroup("AtlasLoading" .. tabpage, { clear = true })
	local indicator
	---@type AtlasLoadingView
	local view = {
		tabpage = tabpage,
		buf = buf,
		win = win,
		message = message,
		closed = false,
	}
	local function draw()
		if not view.closed then
			M.render(view.buf, view.win, indicator:text(view.message))
		end
	end
	local function delete_group()
		if not pcall(vim.api.nvim_del_augroup_by_id, group) then
			vim.schedule(function()
				pcall(vim.api.nvim_del_augroup_by_id, group)
			end)
		end
	end
	local function close(cancelled)
		if view.closed then
			return
		end
		view.closed = true
		indicator:stop()
		delete_group()
		if vim.api.nvim_tabpage_is_valid(view.tabpage) then
			pcall(vim.cmd, vim.api.nvim_tabpage_get_number(view.tabpage) .. "tabclose")
		end
		if vim.api.nvim_buf_is_valid(view.buf) then
			pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
		end
		if cancelled and on_cancel then
			on_cancel()
		end
	end
	view.update = function(_, next_message)
		view.message = next_message
		draw()
	end
	view.finish = function()
		close(false)
	end
	view.cancel = function()
		close(true)
	end

	indicator = spinner.create({ on_tick = draw })
	vim.keymap.set("n", "q", view.cancel, { buffer = buf, silent = true, nowait = true, desc = "Cancel" })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group,
		callback = draw,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				view.cancel()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				view.cancel()
			end)
		end,
	})
	indicator:start()
	draw()
	return view
end

return M
