local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "AtlasGiteaTheme", { bg = "#171b1a", fg = "#d8e4df", bold = true })
end

return M
