---@class RepositorySidebar
---@field buf integer
---@field win integer
---@field pages RepositoryPage[]
---@field selected integer

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.repository.sidebar")

---@param pane RepositorySidebar
function M.render(pane)
	local lines = {}
	for _, page in ipairs(pane.pages) do
		table.insert(lines, page.icon .. " " .. page.label)
	end

	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(pane.buf, namespace, 0, -1)
	for row, line in ipairs(lines) do
		vim.api.nvim_buf_set_extmark(pane.buf, namespace, row - 1, 0, {
			end_col = #line,
			hl_group = row == pane.selected and "Normal" or "AtlasTextMuted",
		})
	end
	vim.bo[pane.buf].modifiable = false
end

return M
