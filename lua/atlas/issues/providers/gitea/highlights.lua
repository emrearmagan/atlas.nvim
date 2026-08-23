local M = {}

local groups = {
	AtlasGiteaIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasGiteaIssueClosed = { fg = "#a371f7", bold = true },
	AtlasGiteaIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGiteaIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },
}

function M.setup()
	require("atlas.providers.gitea.highlights").setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
