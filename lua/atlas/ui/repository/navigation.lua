---@class RepositoryNavigation
---@field buf integer
---@field win integer
---@field pages RepositoryPage[]
---@field selected integer
---@field positions { row: integer, col: integer, end_col: integer }[]

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.repository.navigation")

---@param pane RepositoryNavigation
function M.render(pane)
	local width = vim.api.nvim_win_get_width(pane.win)
	pane.positions = {}
	local lines = { "" }
	local used = 0
	for index, page in ipairs(pane.pages) do
		local item = " " .. page.icon .. " " .. page.label .. " "
		local gap = used > 0 and "  " or ""
		local item_width = vim.api.nvim_strwidth(item)
		if index > 1 and used + #gap + item_width > width then
			table.insert(lines, "")
			used = 0
			gap = ""
		end
		local row = #lines
		local col = #lines[row] + #gap
		lines[row] = lines[row] .. gap .. item
		pane.positions[index] = { row = row, col = col, end_col = col + #item }
		used = used + #gap + item_width
	end

	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(pane.buf, namespace, 0, -1)
	for index, position in ipairs(pane.positions) do
		vim.api.nvim_buf_set_extmark(pane.buf, namespace, position.row - 1, position.col, {
			end_col = position.end_col,
			hl_group = index == pane.selected and "AtlasRelatedChip" or "AtlasTextMuted",
		})
	end
	vim.bo[pane.buf].modifiable = false

	if vim.api.nvim_win_get_height(pane.win) ~= #lines then
		vim.api.nvim_win_set_height(pane.win, #lines)
	end
end

---@param pane RepositoryNavigation
---@return integer|nil
function M.index_at_cursor(pane)
	local cursor = vim.api.nvim_win_get_cursor(pane.win)
	for index, position in ipairs(pane.positions) do
		if cursor[1] == position.row and cursor[2] >= position.col and cursor[2] < position.end_col then
			return index
		end
	end
	return nil
end

---@param pane RepositoryNavigation
function M.focus(pane)
	local position = pane.positions[pane.selected]
	if position then
		vim.api.nvim_win_set_cursor(pane.win, { position.row, position.col })
	end
end

return M
