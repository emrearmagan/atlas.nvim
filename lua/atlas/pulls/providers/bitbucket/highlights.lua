local M = {}

---@type table<string, table>
local groups = {
	AtlasBitbucketTheme = { bg = "#1e3a8a", bold = true },
	AtlasBitbucketPROpen = { fg = "#0b1320", bg = "#93c5fd", bold = true },
	AtlasBitbucketPRMerged = { fg = "#0b1320", bg = "#86efac", bold = true },
	AtlasBitbucketPRDeclined = { fg = "#0b1320", bg = "#fca5a5", bold = true },
	AtlasBitbucketPRDraft = { fg = "#111827", bg = "#fcd34d", bold = true },
	AtlasPipelineLinkSuccess = { fg = "#a6da95", bold = true, underline = true },
	AtlasPipelineLinkFailed = { fg = "#f38ba8", bold = true, underline = true },
	AtlasPipelineLinkInProgress = { fg = "#f9e2af", bold = true, underline = true },
	AtlasPipelineLinkMuted = { fg = "#7f849c", underline = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
