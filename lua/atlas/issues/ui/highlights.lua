local M = {}

local shared = require("atlas.ui.shared.highlights")

---@type table<string, table>
local groups = {
	AtlasIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasIssueClosed = { fg = "#a371f7", bold = true },
	AtlasIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasIssueClosedChip = { fg = "#1e1e2e", bg = "#a371f7", bold = true },

	AtlasJiraKey = { fg = "#89b4fa", bold = true },
	AtlasJiraEpic = { link = "AtlasLogWarn" },
	AtlasJiraChipStoryPoints = { bg = "#f38ba8", bold = true },
	AtlasJiraChipDueDate = { bg = "#f9e2af", bold = true },
	AtlasJiraChipParent = { link = "AtlasJiraTheme" },
	AtlasShortcutChipParent = { link = "AtlasShortcutTheme" },
}

function M.setup()
	shared.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
