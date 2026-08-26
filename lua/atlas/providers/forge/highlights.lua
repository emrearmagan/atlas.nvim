local M = {}

local groups = {
	AtlasGiteaTheme = { bg = "#609926", fg = "#1e1e2e", bold = true },
	AtlasForgejoTheme = { bg = "#fb923c", fg = "#1e1e2e", bold = true },
	AtlasGiteaIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasGiteaIssueClosed = { fg = "#a371f7", bold = true },
	AtlasGiteaIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGiteaIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },
	AtlasForgejoIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasForgejoIssueClosed = { fg = "#a371f7", bold = true },
	AtlasForgejoIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasForgejoIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
