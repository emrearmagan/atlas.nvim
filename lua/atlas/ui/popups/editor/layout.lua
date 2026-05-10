local M = {}

local renderer = require("atlas.ui.popups.editor.renderer")

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param buf integer|nil
---@param on_quit fun()
local function setup_buffer_quit_cmd(buf, on_quit)
	if not valid_buf(buf) then
		return
	end

	pcall(vim.api.nvim_buf_del_user_command, buf, "AtlasEditorQuit")
	vim.api.nvim_buf_create_user_command(buf, "AtlasEditorQuit", function()
		on_quit()
	end, { desc = "Close Atlas editor" })

	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent! cunabbrev <buffer> q")
		vim.cmd("silent! cunabbrev <buffer> quit")
		vim.cmd("cnoreabbrev <buffer> q AtlasEditorQuit")
		vim.cmd("cnoreabbrev <buffer> quit AtlasEditorQuit")
	end)
end

---@param kind "win"|"buf"
---@param id integer|nil
local function close_target(kind, id)
	if kind == "win" then
		if valid_win(id) then
			vim.api.nvim_win_close(id, true)
		end
		return
	end

	if valid_buf(id) then
		vim.api.nvim_buf_delete(id, { force = true })
	end
end

---@param layout EditorPopupLayout
function M.close(layout)
	close_target("win", layout.desc_win)
	close_target("win", layout.meta_win)
	close_target("win", layout.title_win)
	close_target("win", layout.container_win)

	close_target("buf", layout.desc_buf)
	close_target("buf", layout.meta_buf)
	close_target("buf", layout.title_buf)
	close_target("buf", layout.container_buf)
end

---@param opts { buftype: string, modifiable: boolean, name: string, filetype?: string }
---@return integer
local function create_editor_buffer(opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", opts.buftype, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	if opts.filetype then
		vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
	end
	vim.api.nvim_set_option_value("modifiable", opts.modifiable, { buf = buf })
	pcall(vim.api.nvim_buf_set_name, buf, opts.name)
	return buf
end

---@param opts { buffer: integer, enter: boolean, parent: integer, width: integer, height: integer, row: integer, col: integer, focusable?: boolean, wrap: boolean, winbar?: string }
---@return integer
local function open_editor_window(opts)
	local win = vim.api.nvim_open_win(opts.buffer, opts.enter, {
		relative = "win",
		win = opts.parent,
		width = opts.width,
		height = opts.height,
		row = opts.row,
		col = opts.col,
		style = "minimal",
		border = "none",
		focusable = opts.focusable,
	})

	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("wrap", opts.wrap, { win = win })

	if opts.winbar then
		vim.api.nvim_set_option_value("winbar", opts.winbar, { win = win })
	end

	return win
end

---@param opts EditorPopupOpenOpts
---@return string
local function footer_text(opts)
	local footer = "q/:q close"
	footer = footer .. " | <C-s> submit | <Tab> next field"

	for _, keymap in ipairs(opts.keymaps or {}) do
		if keymap.show_in_footer == true then
			footer = footer .. string.format(" | %s %s", keymap.key, keymap.desc)
		end
	end

	return " " .. footer .. " "
end

---@param state { layout: EditorPopupLayout }
---@param name EditorPopupBufferName
---@return integer|nil
local function buffer_for(state, name)
	return state.layout[name .. "_buf"]
end

---@param state { layout: EditorPopupLayout }
---@param name EditorPopupBufferName
local function jump_to(state, name)
	local win = state.layout[name .. "_win"]
	if valid_win(win) then
		vim.api.nvim_set_current_win(win)
	end
end

---@param buf integer|nil
---@param mode string|string[]
---@param lhs string
---@param rhs function
---@param desc string|nil
local function set_keymap(buf, mode, lhs, rhs, desc)
	if valid_buf(buf) then
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
	end
end

---@param state { layout: EditorPopupLayout }
---@param opts EditorPopupOpenOpts
local function setup_default_keymaps(state, opts)
	local function submit()
		vim.cmd("stopinsert")
		opts.submit()
	end

	local function title_to_desc()
		vim.cmd("stopinsert")
		jump_to(state, "desc")
	end

	local function desc_to_title()
		vim.cmd("stopinsert")
		jump_to(state, "title")
	end

	setup_buffer_quit_cmd(state.layout.title_buf, opts.close)
	setup_buffer_quit_cmd(state.layout.meta_buf, opts.close)
	setup_buffer_quit_cmd(state.layout.desc_buf, opts.close)

	local title_buf = state.layout.title_buf
	set_keymap(title_buf, "n", "q", opts.close, "Close editor")
	set_keymap(title_buf, "n", "<CR>", title_to_desc, "Focus description")
	set_keymap(title_buf, "n", "<Tab>", title_to_desc, "Next field")
	set_keymap(title_buf, "n", "<S-Tab>", title_to_desc, "Previous field")
	set_keymap(title_buf, { "n", "i" }, "<C-j>", title_to_desc, "Focus description")
	set_keymap(title_buf, { "n", "i" }, "<C-k>", desc_to_title, "Focus title")
	set_keymap(title_buf, "i", "<CR>", title_to_desc, "Focus description")
	set_keymap(title_buf, "i", "<Tab>", title_to_desc, "Next field")
	set_keymap(title_buf, { "n", "i" }, "<C-s>", submit, "Submit")

	local meta_buf = state.layout.meta_buf
	set_keymap(meta_buf, "n", "q", opts.close, "Close editor")
	set_keymap(meta_buf, "n", "<Tab>", function()
		jump_to(state, "desc")
	end, "Next field")
	set_keymap(meta_buf, "n", "<S-Tab>", function()
		jump_to(state, "title")
	end, "Previous field")
	set_keymap(meta_buf, "n", "<C-j>", function()
		jump_to(state, "desc")
	end, "Focus description")
	set_keymap(meta_buf, "n", "<C-k>", function()
		jump_to(state, "title")
	end, "Focus title")
	set_keymap(meta_buf, "n", "<C-s>", opts.submit, "Submit")

	local desc_buf = state.layout.desc_buf
	set_keymap(desc_buf, "n", "q", opts.close, "Close editor")
	set_keymap(desc_buf, "n", "<Tab>", desc_to_title, "Next field")
	set_keymap(desc_buf, "n", "<S-Tab>", desc_to_title, "Previous field")
	set_keymap(desc_buf, { "n", "i" }, "<C-j>", function()
		vim.cmd("stopinsert")
		jump_to(state, "desc")
	end, "Focus description")
	set_keymap(desc_buf, { "n", "i" }, "<C-k>", desc_to_title, "Focus title")
	set_keymap(desc_buf, { "n", "i" }, "<C-s>", submit, "Submit")
end

---@param state { layout: EditorPopupLayout }
---@param keymaps EditorPopupKeymap[]|nil
local function setup_custom_keymaps(state, keymaps)
	for _, keymap in ipairs(keymaps or {}) do
		for _, name in ipairs(keymap.buffers or {}) do
			set_keymap(buffer_for(state, name), keymap.mode or "n", keymap.key, keymap.action, keymap.desc)
		end
	end
end

---@param state { layout: EditorPopupLayout, content_width: integer }
---@param opts EditorPopupOpenOpts
function M.open(state, opts)
	state.layout = state.layout or {}

	local width = math.max(math.floor(vim.o.columns * 0.75), 80)
	local height = math.max(math.floor(vim.o.lines * 0.75), opts.min_height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local inner_width = width - 2
	local content_width = inner_width - 4
	local content_col = 2
	local meta_row = 4
	local desc_row = meta_row + opts.meta_height + 1

	state.content_width = content_width

	state.layout.container_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.layout.container_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.layout.container_buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = state.layout.container_buf })

	state.layout.container_win = vim.api.nvim_open_win(state.layout.container_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		focusable = false,
		mouse = false,
		title = opts.title,
		title_pos = "center",
		footer = footer_text(opts),
		footer_pos = "center",
	})
	vim.api.nvim_set_option_value("wrap", false, { win = state.layout.container_win })

	state.layout.title_buf = create_editor_buffer({
		buftype = "nofile",
		modifiable = true,
		name = "atlas://editor/title",
	})

	state.layout.meta_buf = create_editor_buffer({
		buftype = "nofile",
		modifiable = false,
		name = "atlas://editor/meta",
	})

	state.layout.desc_buf = create_editor_buffer({
		buftype = "nofile",
		modifiable = true,
		name = "atlas://editor/description.md",
		filetype = "markdown",
	})

	vim.api.nvim_buf_set_lines(state.layout.title_buf, 0, -1, false, { opts.initial_title })
	vim.api.nvim_buf_set_lines(
		state.layout.desc_buf,
		0,
		-1,
		false,
		vim.split(opts.initial_body, "\n", { plain = true })
	)

	local separator = string.rep("─", inner_width)
	vim.api.nvim_buf_set_lines(state.layout.container_buf, 0, -1, false, vim.fn["repeat"]({ "" }, height))

	state.layout.title_win = open_editor_window({
		buffer = state.layout.title_buf,
		enter = true,
		parent = state.layout.container_win,
		width = content_width,
		height = 2,
		row = 0,
		col = content_col,
		wrap = false,
		winbar = opts.title_winbar,
	})

	state.layout.meta_win = open_editor_window({
		buffer = state.layout.meta_buf,
		enter = false,
		parent = state.layout.container_win,
		width = content_width,
		height = opts.meta_height,
		row = meta_row,
		col = content_col,
		focusable = false,
		wrap = false,
	})

	state.layout.desc_win = open_editor_window({
		buffer = state.layout.desc_buf,
		enter = false,
		parent = state.layout.container_win,
		width = content_width,
		height = math.max(1, height - desc_row - 1),
		row = desc_row,
		col = content_col,
		wrap = true,
		winbar = opts.desc_winbar,
	})

	vim.api.nvim_buf_set_lines(state.layout.container_buf, 3, 4, false, { separator })
	vim.api.nvim_buf_set_lines(state.layout.container_buf, desc_row - 1, desc_row, false, { separator })

	renderer.render_meta(state, opts.meta())
	setup_default_keymaps(state, opts)
	setup_custom_keymaps(state, opts.keymaps)
end

return M
