local M = {}
local spinner_component = require("atlas.ui.components.spinner")

local win = nil
local buf = nil
local current_msg = "Loading..."

local spinner_instance = nil

local function close_win()
	if win ~= nil and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	win = nil
end

local function delete_buf()
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	buf = nil
end

local function popup_config(text)
	local width = math.max(vim.fn.strdisplaywidth(text) + 4, 18)
	local height = 1
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 260,
		focusable = false,
	}
end

local function ensure_buf()
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "atlas", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)

	return buf
end

local function render_frame()
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local text = " " .. spinner_instance:text(current_msg)

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	if win ~= nil and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, popup_config(text))
	end
end

local function ensure_spinner()
	if spinner_instance ~= nil then
		return
	end

	spinner_instance = spinner_component.create({
		interval_ms = 90,
		on_tick = function()
			render_frame()
		end,
	})
end

---@param msg string|nil
function M.start(msg)
	current_msg = (msg ~= nil and msg ~= "") and msg or "Loading..."
	ensure_spinner()

	local b = ensure_buf()
	local initial_text = " " .. spinner_instance:text(current_msg)
	local cfg = popup_config(initial_text)

	if win == nil or not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_open_win(b, false, cfg)
	else
		vim.api.nvim_win_set_buf(win, b)
		vim.api.nvim_win_set_config(win, cfg)
	end

	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)

	spinner_instance:start()
end

function M.stop()
	if spinner_instance ~= nil then
		spinner_instance:stop()
	end
	close_win()
	delete_buf()
end

local resize_group = vim.api.nvim_create_augroup("AtlasSpinnerResize", { clear = true })
vim.api.nvim_create_autocmd("VimResized", {
	group = resize_group,
	callback = function()
		if win ~= nil and vim.api.nvim_win_is_valid(win) and buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
			local line = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
			vim.api.nvim_win_set_config(win, popup_config(line))
		end
	end,
})

return M
