local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "AtlasForgejoTheme", { bg = "#fb923c", fg = "#1e1e2e", bold = true })
end

return M
