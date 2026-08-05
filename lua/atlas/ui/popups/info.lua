local M = {}

local ns = vim.api.nvim_create_namespace("atlas.popup.info")

local win = nil
local buf = nil

local function valid_buf(b)
	return type(b) == "number" and vim.api.nvim_buf_is_valid(b)
end

local function valid_win(w)
	return type(w) == "number" and vim.api.nvim_win_is_valid(w)
end

local function close_win()
	if win and valid_win(win) then
		vim.api.nvim_win_close(win, true)
	end
	win = nil
end

local function delete_buf()
	if buf and valid_buf(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	buf = nil
end

local function max_line_width(lines)
	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	return width
end

local function popup_config(lines)
	local content_width = max_line_width(lines)
	local width = math.max(10, math.min(content_width + 2, math.max(vim.o.columns - 4, 10)))
	local height = math.max(1, math.min(#lines, math.max(vim.o.lines - 4, 1)))

	return {
		relative = "cursor",
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
		focusable = false,
		zindex = 260,
		width = width,
		height = height,
	}
end

---@return integer
local function ensure_buf()
	if valid_buf(buf) then
		---@cast buf integer
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

function M.close()
	close_win()
	delete_buf()
end

---@param opts { lines: string[], highlights: AtlasUIHighlight[]|nil, source_buf: integer|nil }
function M.show(opts)
	opts = opts or {}
	local lines = opts.lines or {}
	if #lines == 0 then
		return
	end

	local source_buf = opts.source_buf
	if not valid_buf(source_buf) then
		source_buf = vim.api.nvim_get_current_buf()
	end

	M.close()

	local target_buf = ensure_buf()
	vim.api.nvim_set_option_value("modifiable", true, { buf = target_buf })
	vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = target_buf })
	apply_highlights(target_buf, opts.highlights or {})

	win = vim.api.nvim_open_win(target_buf, false, popup_config(lines))
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
		buffer = source_buf,
		once = true,
		callback = function()
			M.close()
		end,
	})
end

return M
