local M = {}

---@type table<string, table>
local groups = {
	AtlasJiraTheme = { bg = "#1e3a8a", bold = true },
	AtlasJiraKey = { fg = "#89b4fa", bold = true },
	AtlasJiraTitle = { link = "CursorLineNr" },
	AtlasJiraEpic = { link = "AtlasLogWarn" },
	AtlasJiraChipStoryPoints = { bg = "#f38ba8", bold = true },
	AtlasJiraChipDueDate = { bg = "#f9e2af", bold = true },
	AtlasJiraChipParent = { link = "AtlasJiraTheme" },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
