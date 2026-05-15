local M = {}

---@type table<string, table>
local groups = {
	AtlasGHIssuesTheme = { bg = "#1f2328", fg = "#f0f6fc", bold = true },
	AtlasGHIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasGHIssueClosed = { fg = "#a371f7", bold = true },
	AtlasGHIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGHIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },
	AtlasGHIssueKey = { fg = "#58a6ff", bold = true },
	AtlasGHIssueChipRepo = { fg = "#0b1320", bg = "#58a6ff", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
