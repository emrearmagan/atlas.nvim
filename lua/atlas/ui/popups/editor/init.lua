local M = {}

local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local utils = require("atlas.ui.shared.utils")
local statusline = require("atlas.ui.statusline")
local virtual_lines = require("atlas.ui.components.virtual_lines")

local completion_provider_by_buf = {}
local preview_namespace = vim.api.nvim_create_namespace("atlas.editor.preview")
local MAX_PREVIEW_LINES = 11

---@param buf integer
---@param preview AtlasEditorPreview|nil
---@param width integer
local function render_preview(buf, preview, width)
	vim.api.nvim_buf_clear_namespace(buf, preview_namespace, 0, -1)
	if not preview then
		return
	end

	local lines = virtual_lines.render(preview.lines, preview.highlights, {
		width = width,
		background_hl_group = "Pmenu",
	})
	table.insert(lines, { { string.rep("─", width), "AtlasBorder" } })
	vim.api.nvim_buf_set_extmark(buf, preview_namespace, 0, 0, {
		virt_lines = lines,
		virt_lines_above = true,
		right_gravity = false,
	})
end

---@class AtlasMarkdownCompletionProvider
---@field trigger string|nil
---@field find_start fun(before: string, line: string, col: integer): integer|nil
---@field complete fun(base: string, line: string, col: integer): table[]|nil
---@field format_mention (fun(author: AtlasUser|PullsAuthor|nil): string)|nil

---@param findstart integer
---@param base string
---@return integer|table[]
local function complete(findstart, base)
	local buf = vim.api.nvim_get_current_buf()
	local provider = completion_provider_by_buf[buf]
	if type(provider) ~= "table" then
		return findstart == 1 and -2 or {}
	end

	if findstart == 1 then
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local before = line:sub(1, col)
		local start = provider.find_start(before, line, col)
		if type(start) ~= "number" then
			return -2
		end
		return start
	end

	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local items = provider.complete(tostring(base or ""), line, col)
	if type(items) ~= "table" then
		return {}
	end
	return items
end

_G.__atlas_markdown_complete = complete

---@class AtlasEditorAction
---@field key string
---@field description string|nil
---@field callback fun(ctx: AtlasEditorActionContext)
---@field mode string|string[]|nil

---@class AtlasEditorActionContext
---@field buf integer
---@field win integer
---@field close fun()
---@field get_text fun(): string
---@field set_text fun(text: string)

---@class AtlasEditorPreview
---@field lines string[]
---@field highlights AtlasUIHighlight[]|nil
---@field selection { first: integer, last: integer }|nil Selected rows in the preview, starting at 1.

---@class AtlasEditorOptions
---@field key string
---@field title string|nil
---@field title_pos "left"|"center"|"right"|nil
---@field initial_text string|nil
---@field width_ratio number|nil
---@field height_ratio number|nil
---@field on_save fun(text: string)|nil
---@field on_cancel fun()|nil
---@field actions AtlasEditorAction[]|nil
---@field completion AtlasMarkdownCompletionProvider|nil
---@field preview AtlasEditorPreview|nil

---@param preview AtlasEditorPreview
---@param max_lines integer
---@return AtlasEditorPreview|nil
local function limit_preview(preview, max_lines)
	if #preview.lines == 0 or max_lines < 3 then
		return
	end

	local first, last = 1, #preview.lines
	if preview.selection then
		local selected = preview.selection
		local count = selected.last - selected.first + 1
		local context = math.max(0, math.min(2, math.floor((max_lines - count) / 2)))
		first = math.max(1, selected.first - context)
		last = math.min(#preview.lines, selected.last + context)
	end

	local count = last - first + 1
	if first == 1 and last == #preview.lines and count <= max_lines then
		return preview
	end

	local lines, rows = {}, {}
	local function append(from, to)
		for row = from, to do
			rows[row - 1] = #lines
			lines[#lines + 1] = preview.lines[row]
		end
	end

	if count > max_lines then
		local head = math.ceil((max_lines - 1) / 2)
		local tail = max_lines - head - 1
		append(first, first + head - 1)
		lines[#lines + 1] = string.format("… %d lines omitted …", count - head - tail)
		append(last - tail + 1, last)
	else
		append(first, last)
	end

	local highlights = {}
	for _, highlight in ipairs(preview.highlights or {}) do
		local row = rows[highlight.line]
		if row then
			highlights[#highlights + 1] = vim.tbl_extend("force", highlight, { line = row })
		end
	end

	return { lines = lines, highlights = highlights }
end

---@param opts AtlasEditorOptions
---@return integer|nil, integer|nil
function M.open(opts)
	if type(opts) ~= "table" then
		return nil, nil
	end

	local key = tostring(opts.key or "")
	if key == "" then
		notify.warn("Missing editor key")
		return nil, nil
	end
	local source_win = vim.api.nvim_get_current_win()
	local submit_keys = keymaps.resolve("ui.submit") or {}
	local close_keys = keymaps.resolve("ui.close") or {}

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local name = string.format("atlas://editor/%s", key)
	pcall(vim.api.nvim_buf_set_name, buf, name)

	local lines = vim.split(utils.normalize_newlines(opts.initial_text), "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local width_ratio = tonumber(opts.width_ratio) or 0.8
	local height_ratio = tonumber(opts.height_ratio) or 0.8
	local min_width = 80
	local min_height = 12
	local preview, preview_height

	local function geometry()
		local available_width = math.max(1, vim.o.columns - 2)
		local available_height = math.max(1, vim.o.lines - 4)
		local width = math.min(math.max(math.floor(vim.o.columns * width_ratio), min_width), available_width)
		local height = math.min(math.max(math.floor(vim.o.lines * height_ratio), min_height), available_height)

		local max_preview_lines = math.min(MAX_PREVIEW_LINES, available_height - height - 1)
		preview = opts.preview and limit_preview(opts.preview, max_preview_lines)
		preview_height = preview and #preview.lines + 1 or 0
		height = height + preview_height

		local row = math.max(0, math.floor((vim.o.lines - height) / 2))
		local col = math.max(0, math.floor((vim.o.columns - width) / 2))
		return width, height, row, col
	end

	local width, height, row, col = geometry()
	if preview then
		render_preview(buf, preview, width)
	end
	local footer_items = {}
	if #close_keys > 0 then
		table.insert(footer_items, string.format("%s quit", table.concat(close_keys, " / ")))
	end
	if #submit_keys > 0 then
		table.insert(footer_items, string.format("%s save+close", table.concat(submit_keys, " / ")))
	end
	for _, action in ipairs(opts.actions or {}) do
		local description = action.description
		if description and description ~= "" then
			table.insert(footer_items, string.format("%s %s", action.key, description))
		end
	end

	local footer_text = #footer_items > 0 and " " .. table.concat(footer_items, " | ") .. " " or nil
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = row,
		col = col,
		title = opts.title,
		title_pos = opts.title_pos or "center",
		footer = footer_text,
		footer_pos = footer_text and "center" or nil,
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("diff", false, { win = win })
	vim.api.nvim_set_option_value("scrollbind", false, { win = win })
	vim.api.nvim_set_option_value("cursorbind", false, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	statusline.inherit(win, source_win)
	local function reveal_preview()
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview({ topline = 1, topfill = preview_height })
		end)
	end
	if preview then
		-- Virtual lines above line one need topfill to enter the window.
		reveal_preview()
	end

	local completion = opts.completion
	if completion ~= nil then
		completion_provider_by_buf[buf] = completion
		vim.api.nvim_set_option_value("completeopt", "menu,menuone,noselect,noinsert", { buf = buf })
		vim.api.nvim_set_option_value("completefunc", "v:lua.__atlas_markdown_complete", { buf = buf })

		local function open_completion_popup()
			local provider = completion_provider_by_buf[buf]
			if provider == nil then
				return
			end

			if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
				return
			end
			if vim.fn.mode() ~= "i" or vim.fn.pumvisible() == 1 then
				return
			end

			local start = complete(1, "")
			if type(start) ~= "number" or start < 0 then
				return
			end

			local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
			local base = vim.api.nvim_get_current_line():sub(start + 1, cursor_col)
			local items = complete(0, base)
			if type(items) ~= "table" or #items == 0 then
				return
			end

			vim.fn.complete(start + 1, items)
		end

		local trigger = completion.trigger
		if type(trigger) == "string" and trigger ~= "" then
			vim.keymap.set("i", trigger, function()
				local provider = completion_provider_by_buf[buf]
				if provider == nil then
					return trigger
				end
				vim.schedule(open_completion_popup)
				return trigger
			end, { buffer = buf, silent = true, nowait = true, expr = true })
		end

		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				completion_provider_by_buf[buf] = nil
			end,
		})
	end

	local group = vim.api.nvim_create_augroup("AtlasEditor" .. buf, { clear = true })
	if opts.preview then
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = group,
			buffer = buf,
			callback = function()
				if preview and vim.api.nvim_win_get_cursor(win)[1] == 1 then
					reveal_preview()
				end
			end,
		})
	end
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			local resized_width, resized_height, resized_row, resized_col = geometry()
			render_preview(buf, preview, resized_width)
			vim.api.nvim_win_set_config(win, {
				relative = "editor",
				width = resized_width,
				height = resized_height,
				row = resized_row,
				col = resized_col,
			})
			if vim.api.nvim_win_get_cursor(win)[1] == 1 then
				reveal_preview()
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		once = true,
		callback = function()
			vim.api.nvim_del_augroup_by_id(group)
		end,
	})

	local function close_editor()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_win_is_valid(source_win) then
			vim.api.nvim_set_current_win(source_win)
		end
	end

	local function get_text()
		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end

	local function set_text(text)
		local new_lines = vim.split(utils.normalize_newlines(text), "\n", { plain = true })
		if #new_lines == 0 then
			new_lines = { "" }
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.api.nvim_win_set_cursor(win, { #new_lines, #new_lines[#new_lines] })
		if preview then
			reveal_preview()
		end
	end

	for _, close_key in ipairs(close_keys) do
		vim.keymap.set("n", close_key, function()
			if opts.on_cancel then
				opts.on_cancel()
			end
			close_editor()
		end, { buffer = buf, silent = true, nowait = true })
	end

	local function save_and_close()
		local body = get_text()
		close_editor()

		if opts.on_save then
			opts.on_save(body)
		end
	end

	for _, submit_key in ipairs(submit_keys) do
		vim.keymap.set("n", submit_key, save_and_close, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("i", submit_key, function()
			vim.cmd("stopinsert")
			save_and_close()
		end, { buffer = buf, silent = true, nowait = true })
	end

	for _, action in ipairs(opts.actions or {}) do
		vim.keymap.set(action.mode or "n", action.key, function()
			local ok, err = pcall(action.callback, {
				buf = buf,
				win = win,
				close = close_editor,
				get_text = get_text,
				set_text = set_text,
			})
			if not ok then
				notify.error(tostring(err or "Markdown action failed"))
			end
		end, { buffer = buf, silent = true, nowait = true, desc = action.description })
	end

	return buf, win
end

return M
