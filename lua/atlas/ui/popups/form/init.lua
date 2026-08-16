local M = {}

local keymaps = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")
local renderer = require("atlas.ui.popups.form.renderer")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")
local valid_buf = utils.buffer.valid
local valid_tab = utils.tab.valid
local valid_win = utils.window.valid

local next_id = 0

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
	for _, name in ipairs({ "editor", "context" }) do
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
	statusline.clear_notice()
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
---@param opts { wrap?: boolean, winbar?: string, fixed_height?: boolean }
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
	statusline.attach(win)
	vim.api.nvim_set_option_value("winfixheight", opts.fixed_height == true, { win = win })
	vim.api.nvim_set_option_value("winbar", opts.winbar or "", { win = win })
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
---@param opts AtlasFormOpenOpts
local function build_layout(layout, opts)
	layout.editor_win = vim.api.nvim_get_current_win()
	configure_window(layout.editor_win, layout.editor_buf, { wrap = true })
	open_context(layout, layout.editor_win, opts)
end

---@param state { layout: AtlasFormLayout }
---@param name AtlasFormBufferName
---@return integer|nil
local function buffer_for(state, name)
	return state.layout[name .. "_buf"]
end

---@param keymap AtlasFormKeymap
---@param name AtlasFormBufferName
---@return boolean
local function applies_to(keymap, name)
	for _, target in ipairs(keymap.buffers) do
		if target == name then
			return true
		end
	end
	return false
end

---@param state { layout: AtlasFormLayout }
---@param opts AtlasFormOpenOpts
---@param name AtlasFormBufferName
---@param buf integer
local function setup_keymaps(state, opts, name, buf)
	local items = {}
	local submit_keys = keymaps.resolve("ui.submit")
	if submit_keys then
		items[#items + 1] = {
			key = #submit_keys == 1 and submit_keys[1] or submit_keys,
			mode = { "n", "i" },
			desc = "Submit",
			callback = function()
				vim.cmd("stopinsert")
				opts.submit()
			end,
			opts = { silent = true, nowait = true },
		}
	end
	items[#items + 1] = {
		key = "q",
		desc = "Close",
		callback = opts.close,
		opts = { silent = true, nowait = true },
	}

	if name == "editor" then
		items[#items + 1] = {
			key = "gg",
			desc = "Go to first line",
			callback = function()
				vim.cmd("normal! gg")
				renderer.reveal_meta(state.layout)
			end,
			opts = { silent = true, nowait = true },
		}
	end

	for _, keymap in ipairs(opts.keymaps or {}) do
		if applies_to(keymap, name) then
			items[#items + 1] = {
				key = keymap.key,
				mode = keymap.mode,
				desc = keymap.desc,
				callback = keymap.action,
				opts = { silent = true, nowait = true },
			}
		end
	end

	local help_keys = keymaps.resolve("ui.help")
	if help_keys then
		items[#items + 1] = {
			key = #help_keys == 1 and help_keys[1] or help_keys,
			desc = "Toggle help",
			callback = function()
				help.toggle({ buffer = buf })
			end,
			opts = { silent = true, nowait = true },
		}
	end

	setup_buffer_quit_cmd(buf, opts.close)
	help.register("Form", items, { buffer = buf, index = 100 })
end

---@param opts AtlasFormOpenOpts
---@return AtlasStatuslineSegment[]
local function build_statusline_items(opts)
	local items = {}
	local submit_keys = keymaps.resolve("ui.submit")
	if submit_keys then
		items[#items + 1] = {
			text = string.format("%s submit", table.concat(submit_keys, " / ")),
			hl_group = "AtlasFooterText",
		}
	end
	for _, keymap in ipairs(opts.keymaps or {}) do
		local key = type(keymap.key) == "table" and table.concat(keymap.key, " / ") or keymap.key
		items[#items + 1] = {
			text = string.format("%s%s %s", #items > 0 and "| " or "", key, keymap.desc),
			hl_group = "AtlasFooterText",
			priority = 10,
		}
	end
	items[#items + 1] = {
		text = string.format("%sq close", #items > 0 and "| " or ""),
		hl_group = "AtlasFooterText",
	}
	return items
end

---@param state { layout: AtlasFormLayout, content_width: integer }
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
	statusline.clear_notice()

	next_id = next_id + 1
	local prefix = string.format("atlas://create/%d", next_id)
	layout.editor_buf = create_buffer(prefix .. "/form.md", "markdown")
	if opts.context then
		layout.context_buf = create_buffer(prefix .. "/context", nil)
	end

	local lines = { opts.initial_title }
	vim.list_extend(lines, vim.split(opts.initial_body, "\n", { plain = true }))
	if #lines == 1 then
		table.insert(lines, "")
	end
	set_lines(layout.editor_buf, lines, true)
	if layout.context_buf then
		set_lines(layout.context_buf, { "" }, false)
	end

	vim.cmd("tabnew")
	layout.tab = vim.api.nvim_get_current_tabpage()
	layout.placeholder_buf = vim.api.nvim_get_current_buf()

	statusline.set_items(build_statusline_items(opts))
	build_layout(layout, opts)
	state.content_width = valid_win(layout.editor_win) and vim.api.nvim_win_get_width(layout.editor_win) or 80

	if valid_buf(layout.placeholder_buf) and layout.placeholder_buf ~= layout.editor_buf then
		pcall(vim.api.nvim_buf_delete, layout.placeholder_buf, { force = true })
	end
	layout.placeholder_buf = nil

	render(state, opts)
	for _, name in ipairs({ "editor", "context" }) do
		local buf = buffer_for(state, name)
		if valid_buf(buf) then
			setup_keymaps(state, opts, name, buf)
		end
	end

	layout.augroup = vim.api.nvim_create_augroup("AtlasForm" .. next_id, { clear = true })
	-- Keep an empty line for both the title and description when either one is deleted.
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = layout.augroup,
		buffer = layout.editor_buf,
		callback = function()
			if vim.api.nvim_buf_line_count(layout.editor_buf) == 1 then
				local changed_line = vim.fn.line("'[")
				vim.cmd("silent! undojoin")
				if changed_line == 1 then
					vim.api.nvim_buf_set_lines(layout.editor_buf, 0, 0, false, { "" })
					vim.api.nvim_win_set_cursor(layout.editor_win, { 1, 0 })
				else
					vim.api.nvim_buf_set_lines(layout.editor_buf, 1, -1, false, { "" })
					vim.api.nvim_win_set_cursor(layout.editor_win, { 2, 0 })
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = layout.augroup,
		callback = function()
			if valid_tab(layout.tab) then
				render(state, opts)
			end
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = layout.augroup,
		callback = function()
			if not layout.closing and not valid_tab(layout.tab) then
				layout.closing = true
				statusline.clear_notice()
				delete_buffers(layout)
				if opts.on_closed then
					pcall(opts.on_closed)
				end
				local augroup = layout.augroup
				layout.augroup = nil
				vim.schedule(function()
					pcall(vim.api.nvim_del_augroup_by_id, augroup)
				end)
			end
		end,
	})

	vim.api.nvim_set_current_win(layout.editor_win)
	vim.api.nvim_win_set_cursor(layout.editor_win, { 1, #opts.initial_title })
end

M.render_meta = renderer.render_meta
M.render_context = renderer.render_context
M.notify = statusline.notify
M.clear_notice = statusline.clear_notice

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
