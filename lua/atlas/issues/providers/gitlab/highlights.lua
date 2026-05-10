local M = {}

---@type table<string, table>
local groups = {
	AtlasGLIssuesTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
	AtlasGLIssueOpen = { fg = "#89b4fa", bold = true },
	AtlasGLIssueClosed = { fg = "#cba6f7", bold = true },
	AtlasGLIssueKey = { fg = "#fc6d26", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
