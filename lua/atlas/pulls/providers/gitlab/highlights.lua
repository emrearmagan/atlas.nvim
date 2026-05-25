local M = {}

---@type table<string, table>
local groups = {
	AtlasGitLabTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
	AtlasGLPROpen = { fg = "#89b4fa", bold = true },
	AtlasGLPRMerged = { fg = "#cba6f7", bold = true },
	AtlasGLPRClosed = { fg = "#f38ba8", bold = true },
	AtlasGLPRDraft = { fg = "#6c7086", bold = true },
	AtlasGLPRRef = { fg = "#fc6d26", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
