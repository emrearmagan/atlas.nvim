local M = {}

---@type table<string, table>
local groups = {
	AtlasGitHubTheme = { bg = "#1f2328", fg = "#f0f6fc", bold = true },
	AtlasGitHubPROpen = { fg = "#0b1320", bg = "#3fb950", bold = true },
	AtlasGitHubPRMerged = { fg = "#0b1320", bg = "#a371f7", bold = true },
	AtlasGitHubPRClosed = { fg = "#0b1320", bg = "#f85149", bold = true },
	AtlasGitHubPRDraft = { fg = "#0b1320", bg = "#8b949e", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
