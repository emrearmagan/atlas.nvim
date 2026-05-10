local M = {}

---@type table<string, table>
local groups = {
	AtlasGHIssuesTheme = { fg = "#1e1e2e", bg = "#cdd6f4", bold = true },
	AtlasGHIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasGHIssueClosed = { fg = "#cba6f7", bold = true },
	AtlasGHIssueKey = { fg = "#89b4fa", bold = true },
	AtlasGHIssueChipRepo = { fg = "#1e1e2e", bg = "#89b4fa", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
