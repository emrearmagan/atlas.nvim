local M = {}

---@type table<string, table>
local groups = {
	AtlasGiteaTheme    = { bg = "#161b22", fg = "#f0f6fc", bold = true },
	AtlasGiteaPROpen   = { fg = "#a6e3a1", bold = true },
	AtlasGiteaPRMerged = { fg = "#a371f7", bold = true },
	AtlasGiteaPRDeclined = { fg = "#f38ba8", bold = true },
	AtlasGiteaPRDraft  = { fg = "#89b4fa", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
