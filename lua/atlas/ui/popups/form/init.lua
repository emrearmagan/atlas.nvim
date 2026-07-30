local M = {}

local renderer = require("atlas.ui.popups.form.renderer")

local next_id = 0

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_tab(tab)
	return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

---@param buf integer|nil
---@param on_quit fun()
local function setup_buffer_quit_cmd(buf, on_quit)
	if not valid_buf(buf) then
		return
	end

	pcall(vim.api.nvim_buf_del_user_command, buf, "AtlasEditorQuit")
	vim.api.nvim_buf_create_user_command(buf, "AtlasEditorQuit", on_quit, { desc = "Close Atlas editor" })

	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent! cunabbrev <buffer> q")
		vim.cmd("silent! cunabbrev <buffer> quit")
		vim.cmd("cnoreabbrev <buffer> q AtlasEditorQuit")
		vim.cmd("cnoreabbrev <buffer> quit AtlasEditorQuit")
	end)
end

---@param layout AtlasFormLayout
local function delete_buffers(layout)
	for _, name in ipairs({ "editor", "context", "footer" }) do
		local buf = layout[name .. "_buf"]
		if valid_buf(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

---@param layout AtlasFormLayout
function M.close(layout)
	if layout.closing then
		return
	end
	layout.closing = true
	local return_to_source = valid_tab(layout.tab) and vim.api.nvim_get_current_tabpage() == layout.tab

	if layout.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, layout.augroup)
		layout.augroup = nil
	end

	if valid_tab(layout.tab) then
		local tab_number = vim.api.nvim_tabpage_get_number(layout.tab)
		pcall(vim.cmd, string.format("silent! %dtabclose!", tab_number))
	end

	delete_buffers(layout)

	if return_to_source and valid_tab(layout.source_tab) then
		pcall(vim.api.nvim_set_current_tabpage, layout.source_tab)
		if valid_win(layout.source_win) then
			pcall(vim.api.nvim_set_current_win, layout.source_win)
		end
	end
end

---@param name string
---@param filetype string|nil
---@return integer
local function create_buffer(name, filetype)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	if filetype then
		vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
	end
	pcall(vim.api.nvim_buf_set_name, buf, name)
	return buf
end

---@param buf integer
---@param lines string[]
---@param modifiable boolean
local function set_lines(buf, lines, modifiable)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = buf })
end

---@param win integer
---@param buf integer
---@param opts { wrap?: boolean, winbar?: string, fixed_height?: boolean, fixed_width?: boolean }
local function configure_window(win, buf, opts)
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
	vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("foldenable", false, { win = win })
	vim.api.nvim_set_option_value("wrap", opts.wrap == true, { win = win })
	vim.api.nvim_set_option_value("statusline", "%#Normal# ", { win = win })
	vim.api.nvim_set_option_value("winfixheight", opts.fixed_height == true, { win = win })
	vim.api.nvim_set_option_value("winfixwidth", opts.fixed_width == true, { win = win })
	vim.api.nvim_set_option_value("winbar", opts.winbar or "", { win = win })
end

local function footer_config()
	return {
		relative = "editor",
		row = math.max(0, vim.o.lines - math.max(vim.o.cmdheight, 1) - 1),
		col = 0,
		width = math.max(1, vim.o.columns),
		height = 1,
		style = "minimal",
		focusable = false,
		border = "none",
		zindex = 60,
	}
end

---@param layout AtlasFormLayout
local function open_footer(layout)
	layout.footer_win = vim.api.nvim_open_win(layout.footer_buf, false, footer_config())
	configure_window(layout.footer_win, layout.footer_buf, {})
	vim.api.nvim_set_option_value("winbar", "", { win = layout.footer_win })
	vim.api.nvim_set_option_value("statusline", "", { win = layout.footer_win })
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:AtlasFooterBackground,NormalNC:AtlasFooterBackground,EndOfBuffer:AtlasFooterBackground",
		{ win = layout.footer_win }
	)
end

---@param layout AtlasFormLayout
local function reflow_footer(layout)
	if valid_win(layout.footer_win) then
		vim.api.nvim_win_set_config(layout.footer_win, footer_config())
	end
end

---@param parent integer
---@param command string
---@param buf integer
---@return integer
local function split(parent, command, buf)
	vim.api.nvim_set_current_win(parent)
	vim.cmd(command)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	return win
end

local function context_height()
	return math.max(5, math.min(10, math.floor(vim.o.lines * 0.2)))
end

---@param layout AtlasFormLayout
---@param parent integer
---@param opts AtlasFormOpenOpts
local function open_context(layout, parent, opts)
	if not layout.context_buf then
		return
	end
	layout.context_win = split(parent, "belowright split", layout.context_buf)
	vim.api.nvim_win_set_height(layout.context_win, context_height())
	configure_window(layout.context_win, layout.context_buf, {
		winbar = opts.context_title,
		fixed_height = true,
	})
end

---@param layout AtlasFormLayout
local function render_separator(layout)
	if not valid_win(layout.editor_win) then
		return
	end
	local statusline = "%#Normal# "
	if valid_win(layout.context_win) then
		statusline = "%#AtlasBorder#" .. string.rep("─", vim.api.nvim_win_get_width(layout.editor_win))
	end
	vim.api.nvim_set_option_value("statusline", statusline, { win = layout.editor_win })
end

---@param layout AtlasFormLayout
---@param opts AtlasFormOpenOpts
local function build_layout(layout, opts)
	layout.editor_win = vim.api.nvim_get_current_win()
	configure_window(layout.editor_win, layout.editor_buf, { wrap = true })
	open_context(layout, layout.editor_win, opts)
	render_separator(layout)
end

---@param state { layout: AtlasFormLayout }
---@param name AtlasFormBufferName
---@return integer|nil
local function buffer_for(state, name)
	return state.layout[name .. "_buf"]
end

---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs function
---@param desc string
local function set_keymap(buf, mode, lhs, rhs, desc)
	vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
end

---@param opts AtlasFormOpenOpts
---@param buf integer
local function setup_default_keymaps(opts, buf)
	local function submit()
		vim.cmd("stopinsert")
		opts.submit()
	end

	set_keymap(buf, "n", "q", opts.close, "Close")
	set_keymap(buf, { "n", "i" }, "<C-s>", submit, "Submit")
end

---@param state { layout: AtlasFormLayout }
---@param opts AtlasFormOpenOpts
local function setup_keymaps(state, opts)
	for _, name in ipairs({ "editor", "context" }) do
		local buf = buffer_for(state, name)
		if valid_buf(buf) then
			setup_buffer_quit_cmd(buf, opts.close)
			setup_default_keymaps(opts, buf)
		end
	end

	for _, keymap in ipairs(opts.keymaps or {}) do
		for _, name in ipairs(keymap.buffers or {}) do
			local buf = buffer_for(state, name)
			if valid_buf(buf) then
				local keys = type(keymap.key) == "table" and keymap.key or { keymap.key }
				for _, key in ipairs(keys) do
					set_keymap(buf, keymap.mode or "n", key, keymap.action, keymap.desc)
				end
			end
		end
	end
end

---@param state { layout: AtlasFormLayout }
---@param opts AtlasFormOpenOpts
local function render(state, opts)
	renderer.render_meta(state, opts.meta())
	if opts.context then
		renderer.render_context(state, opts.context())
	end
end

---@param state { layout: AtlasFormLayout, content_width: integer }
---@param opts AtlasFormOpenOpts
function M.open(state, opts)
	state.layout = state.layout or {}
	local layout = state.layout
	layout.source_tab = vim.api.nvim_get_current_tabpage()
	layout.source_win = vim.api.nvim_get_current_win()
	layout.title_label = opts.title_label
	layout.body_label = opts.body_label

	next_id = next_id + 1
	local prefix = string.format("atlas://create/%d", next_id)
	layout.editor_buf = create_buffer(prefix .. "/form.md", "markdown")
	layout.footer_buf = create_buffer(prefix .. "/footer", nil)
	if opts.context then
		layout.context_buf = create_buffer(prefix .. "/context", nil)
	end

	local lines = { opts.initial_title }
	vim.list_extend(lines, vim.split(opts.initial_body, "\n", { plain = true }))
	if #lines == 1 then
		table.insert(lines, "")
	end
	set_lines(layout.editor_buf, lines, true)
	set_lines(layout.footer_buf, { "" }, false)
	if layout.context_buf then
		set_lines(layout.context_buf, { "" }, false)
	end

	vim.cmd("tabnew")
	layout.tab = vim.api.nvim_get_current_tabpage()
	layout.placeholder_buf = vim.api.nvim_get_current_buf()

	build_layout(layout, opts)
	open_footer(layout)
	state.content_width = valid_win(layout.editor_win) and vim.api.nvim_win_get_width(layout.editor_win) or 80

	if valid_buf(layout.placeholder_buf) and layout.placeholder_buf ~= layout.editor_buf then
		pcall(vim.api.nvim_buf_delete, layout.placeholder_buf, { force = true })
	end
	layout.placeholder_buf = nil

	render(state, opts)
	setup_keymaps(state, opts)
	renderer.render_footer(layout, opts)

	layout.augroup = vim.api.nvim_create_augroup("AtlasForm" .. next_id, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = layout.augroup,
		callback = function()
			if valid_tab(layout.tab) then
				reflow_footer(layout)
				render_separator(layout)
				render(state, opts)
				renderer.render_footer(layout, opts)
			end
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = layout.augroup,
		callback = function()
			if not layout.closing and not valid_tab(layout.tab) then
				layout.closing = true
				delete_buffers(layout)
				local augroup = layout.augroup
				layout.augroup = nil
				vim.schedule(function()
					pcall(vim.api.nvim_del_augroup_by_id, augroup)
				end)
				if opts.on_closed then
					opts.on_closed()
				end
			end
		end,
	})

	vim.api.nvim_set_current_win(layout.editor_win)
	vim.api.nvim_win_set_cursor(layout.editor_win, { 1, #opts.initial_title })
end

M.render_meta = renderer.render_meta
M.render_context = renderer.render_context

---@param layout AtlasFormLayout
---@return string
function M.get_title(layout)
	if not valid_buf(layout.editor_buf) then
		return ""
	end
	return (vim.api.nvim_buf_get_lines(layout.editor_buf, 0, 1, false)[1] or "")
end

---@param layout AtlasFormLayout
---@return string
function M.get_body(layout)
	if not valid_buf(layout.editor_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(layout.editor_buf, 1, -1, false), "\n")
end

---@param layout AtlasFormLayout
---@param body string
---@return boolean
function M.set_body(layout, body)
	if not valid_buf(layout.editor_buf) then
		return false
	end
	local lines = vim.split(tostring(body or ""), "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	local modifiable = vim.api.nvim_get_option_value("modifiable", { buf = layout.editor_buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = layout.editor_buf })
	vim.api.nvim_buf_set_lines(layout.editor_buf, 1, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = layout.editor_buf })
	return true
end

return M
