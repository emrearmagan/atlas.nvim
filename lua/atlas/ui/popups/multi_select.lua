--- Note: Complety AI generated. But its a pretty simple picker that just works. Dont feel like it needs refactoring (yet..)
---
---@class AtlasMultiSelectOpts
---@field items table[] candidate items
---@field selected table[] current selection
---@field key fun(item: table): string stable identity used for toggling
---@field format fun(item: table): string human label
---@field prompt string|nil window title; defaults to "Select"
---@field on_done fun(selected: table[])|nil called when the selection is applied
---@field on_change fun(selected: table[])|nil called after every toggle

local M = {}

local icons = require("atlas.ui.shared.icons")
local statusline = require("atlas.ui.statusline")

---@param list table[]
---@param key string
---@param key_fn fun(item: table): string
---@return boolean
local function contains(list, key, key_fn)
	for _, item in ipairs(list) do
		if key_fn(item) == key then
			return true
		end
	end
	return false
end

---@param list table[]
---@param key string
---@param key_fn fun(item: table): string
---@return table[]
local function without(list, key, key_fn)
	local kept = {}
	for _, item in ipairs(list) do
		if key_fn(item) ~= key then
			table.insert(kept, item)
		end
	end
	return kept
end

---@param opts AtlasMultiSelectOpts
function M.open(opts)
	if type(opts) ~= "table" then
		return
	end
	if type(opts.items) ~= "table" or type(opts.key) ~= "function" or type(opts.format) ~= "function" then
		return
	end
	local source_win = vim.api.nvim_get_current_win()

	local original = vim.deepcopy(opts.selected or {})
	local selected = vim.deepcopy(original)
	local title = vim.trim(opts.prompt or "Select"):gsub(":$", "")
	local footer = " Space toggle | Enter apply "
	local checkmark = icons.general("success")
	local lines = {}

	local function render()
		lines = {}
		for _, item in ipairs(opts.items) do
			local marker = contains(selected, opts.key(item), opts.key) and checkmark .. " " or "  "
			table.insert(lines, " " .. marker .. opts.format(item))
		end
	end

	render()

	local width = math.max(vim.fn.strdisplaywidth(title) + 2, vim.fn.strdisplaywidth(footer) + 2)
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
	end
	width = math.min(width, math.max(1, vim.o.columns - 4))
	local height = math.min(math.max(1, #lines), math.max(1, vim.o.lines - 4))

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,CursorLine:CursorLine",
		{ win = win }
	)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	statusline.inherit(win, source_win)

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function cancel()
		close()
		if opts.on_done then
			opts.on_done(original)
		elseif opts.on_change then
			opts.on_change(original)
		end
	end

	local function update()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local item = opts.items[row]
		if not item then
			return
		end

		local key = opts.key(item)
		if contains(selected, key, opts.key) then
			selected = without(selected, key, opts.key)
		else
			table.insert(selected, item)
		end

		render()
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		if opts.on_change then
			opts.on_change(selected)
		end
	end

	local key_opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("n", "<C-j>", "j", key_opts)
	vim.keymap.set("n", "<C-k>", "k", key_opts)
	vim.keymap.set("n", "<Space>", update, key_opts)
	vim.keymap.set("n", "<CR>", function()
		close()
		if opts.on_done then
			opts.on_done(selected)
		end
	end, key_opts)
	vim.keymap.set("n", "q", cancel, key_opts)
	vim.keymap.set("n", "<Esc>", cancel, key_opts)
end

return M
