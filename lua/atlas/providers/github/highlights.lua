local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "AtlasGitHubTheme", { bg = "#1f2328", fg = "#f0f6fc", bold = true })
end

return M
