local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "AtlasGitLabTheme", { fg = "#1e1e2e", bg = "#fc6d26", bold = true })
end

return M
