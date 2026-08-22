local M = {}

local groups = {
	AtlasForgejoIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasForgejoIssueClosed = { fg = "#a371f7", bold = true },
	AtlasForgejoIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasForgejoIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },
	AtlasForgejoIssueKey = { fg = "#58a6ff", bold = true },
}

function M.setup()
	require("atlas.providers.forgejo.highlights").setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
