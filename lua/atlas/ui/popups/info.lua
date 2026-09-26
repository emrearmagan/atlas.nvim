local M = {}

local ns = vim.api.nvim_create_namespace("atlas.popup.info")
local group = vim.api.nvim_create_augroup("AtlasInfoPopup", { clear = true })

local win = nil
local buf = nil
local source_win = nil

local function hide()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	win, buf = nil, nil
end

local function max_line_width(lines)
	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	return width
end

local function popup_config(lines, owner)
	local content_width = max_line_width(lines)
	local width = math.max(10, math.min(content_width + 2, math.max(vim.o.columns - 4, 10)))
	local height = 0
	for _, line in ipairs(lines) do
		height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
	end
	local cursor = vim.api.nvim_win_get_cursor(owner)

	return {
		relative = "win",
		win = owner,
		bufpos = { cursor[1] - 1, cursor[2] },
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
		focusable = false,
		zindex = 260,
		width = width,
		height = math.max(1, math.min(height, vim.o.lines - 4)),
	}
end

---@return integer
local function ensure_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	return buf
end

---@param target_buf integer
---@param highlights AtlasUIHighlight[]
local function apply_highlights(target_buf, highlights)
	vim.api.nvim_buf_clear_namespace(target_buf, ns, 0, -1)

	for _, highlight in ipairs(highlights) do
		if highlight.line_hl_group then
			vim.api.nvim_buf_set_extmark(target_buf, ns, highlight.line, 0, {
				line_hl_group = highlight.line_hl_group,
			})
		else
			vim.api.nvim_buf_set_extmark(target_buf, ns, highlight.line, highlight.start_col, {
				end_row = highlight.line,
				end_col = highlight.end_col,
				hl_group = highlight.hl_group,
			})
		end
	end
end

---@param owner integer|nil
function M.close(owner)
	if owner and owner ~= source_win then
		return
	end
	vim.api.nvim_clear_autocmds({ group = group })
	source_win = nil
	hide()
end

---@param content { lines: string[], title?: string, filetype?: string, highlights?: AtlasUIHighlight[] }|nil
---@param owner integer
local function draw(content, owner)
	if not content or #content.lines == 0 then
		hide()
		return
	end

	local target_buf = ensure_buf()
	vim.api.nvim_set_option_value("modifiable", true, { buf = target_buf })
	vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, content.lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = target_buf })
	local filetype = content.filetype or ""
	if vim.bo[target_buf].filetype ~= filetype then
		vim.bo[target_buf].filetype = filetype
	end
	apply_highlights(target_buf, content.highlights or {})

	local config = popup_config(content.lines, owner)
	config.title = content.title or ""
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, config)
	else
		win = vim.api.nvim_open_win(target_buf, false, config)
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true
		vim.wo[win].winhighlight =
			"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder"
	end
end

---@param owner integer
---@param source_buf integer
local function watch_source(owner, source_buf)
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout" }, {
		group = group,
		buffer = source_buf,
		callback = function()
			M.close(owner)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(owner),
		callback = function()
			M.close(owner)
		end,
	})
end

---@param opts { lines: string[], highlights?: AtlasUIHighlight[], source_buf?: integer, title?: string, filetype?: string }
function M.show(opts)
	if #opts.lines == 0 then
		return
	end
	M.close()
	source_win = vim.api.nvim_get_current_win()
	local source_buf = opts.source_buf or vim.api.nvim_get_current_buf()
	draw(opts, source_win)
	watch_source(source_win, source_buf)

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = source_buf,
		callback = function()
			M.close()
		end,
	})
end

---@param opts { source_win: integer, content: fun(line: integer): { lines: string[], title?: string, filetype?: string, highlights?: AtlasUIHighlight[] }|nil }
function M.toggle(opts)
	local owner = opts.source_win
	if source_win == owner then
		M.close()
		return
	end
	M.close()
	source_win = owner
	local source_buf = vim.api.nvim_win_get_buf(owner)
	watch_source(owner, source_buf)

	local function update()
		draw(opts.content(vim.api.nvim_win_get_cursor(owner)[1]), owner)
	end
	update()
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = source_buf,
		callback = update,
	})
end

return M
