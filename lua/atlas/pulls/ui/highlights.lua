local M = {}

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

	AtlasBuildLinkSuccess = { fg = "#a6da95", bold = true, underline = true },
	AtlasBuildLinkFailed = { fg = "#f38ba8", bold = true, underline = true },
	AtlasBuildLinkInProgress = { fg = "#f9e2af", bold = true, underline = true },
	AtlasBuildLinkMuted = { fg = "#7f849c", underline = true },

	AtlasDiffContext = { fg = "#cdd6f4" },
	AtlasDiffAddLine = { bg = "#1e2a1e" },
	AtlasDiffRemoveLine = { bg = "#2a1e1e" },
	AtlasDiffAddMarker = { fg = "#a6da95", bg = "#1e2a1e", bold = true },
	AtlasDiffRemoveMarker = { fg = "#f38ba8", bg = "#2a1e1e", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
