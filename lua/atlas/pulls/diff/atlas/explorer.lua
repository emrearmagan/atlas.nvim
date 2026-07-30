local M = {}

local namespace = vim.api.nvim_create_namespace("atlas_native_diff_explorer")
local WIDTH = 36

local STATUS_MARKERS = {
	added = { "A", "DiagnosticOk" },
	modified = { "M", "DiagnosticWarn" },
	deleted = { "D", "DiagnosticError" },
	renamed = { "R", "DiagnosticInfo" },
	type_changed = { "T", "DiagnosticWarn" },
	unknown = { "?", "AtlasTextMuted" },
}

---@param win integer
function M.configure(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local options = vim.wo[win][0]
	options.cursorline = true
	options.foldcolumn = "0"
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.statuscolumn = ""
	options.wrap = false
	options.winfixwidth = true
	vim.api.nvim_win_set_width(win, math.min(WIDTH, math.max(20, vim.o.columns - 40)))
end

---@param session AtlasNativeDiffSession
function M.render(session)
	local buf = session.panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local lines = {}
	local highlights = {}
	session.panel_items = {}
	table.insert(lines, "Files")
	table.insert(highlights, { 0, 0, #lines[1], "AtlasLogInfo" })
	for index, file in ipairs(session.files) do
		local marker = STATUS_MARKERS[file.status] or STATUS_MARKERS.unknown
		table.insert(lines, string.format(" %s %s", marker[1], file.path))
		local row = #lines - 1
		table.insert(highlights, { row, 1, 2, marker[2] })
		session.panel_items[#lines] = index
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, namespace, highlight[1], highlight[2], {
			end_col = highlight[3],
			hl_group = highlight[4],
		})
	end

	local win = session.panel.win
	local active_index = session.pending_index or session.selected_index
	if win and vim.api.nvim_win_is_valid(win) and active_index then
		local row = M.line_for_file(session, active_index)
		if row then
			pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
		end
	end
end

---@param session AtlasNativeDiffSession
---@return integer|nil
function M.file_at_cursor(session)
	local win = session.panel.win
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	return session.panel_items[vim.api.nvim_win_get_cursor(win)[1]]
end

---@param session AtlasNativeDiffSession
---@param file_index integer
---@return integer|nil
function M.line_for_file(session, file_index)
	for line, index in pairs(session.panel_items) do
		if index == file_index then
			return line
		end
	end
	return nil
end

return M
