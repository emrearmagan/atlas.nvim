local M = {}

local shared = require("atlas.ui.shared.highlights")

---@type table<string, table>
local groups = {
	AtlasPROpen = { fg = "#86efac" },
	AtlasPRMerged = { fg = "#93c5fd" },
	AtlasPRDeclined = { fg = "#fca5a5" },
	AtlasPRDraft = { fg = "#fcd34d" },

	AtlasPROpenChip = { fg = "#0b1320", bg = "#86efac", bold = true },
	AtlasPRMergedChip = { fg = "#0b1320", bg = "#93c5fd", bold = true },
	AtlasPRDeclinedChip = { fg = "#0b1320", bg = "#fca5a5", bold = true },
	AtlasPRDraftChip = { fg = "#111827", bg = "#fcd34d", bold = true },

	AtlasPipelineLinkSuccess = { fg = "#a6da95" },
	AtlasPipelineLinkFailed = { fg = "#f38ba8" },
	AtlasPipelineLinkInProgress = { fg = "#f9e2af" },
	AtlasPipelineLinkMuted = { fg = "#7f849c" },

	AtlasDiffAddLine = { link = "DiffAdd" },
	AtlasDiffChangeLine = { link = "DiffChange" },
	AtlasDiffDeleteFiller = { link = "Comment" },
	AtlasDiffRemoveLine = { link = "DiffDelete" },
}

function M.setup()
	shared.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", opts, { default = true }))
	end
end

return M
