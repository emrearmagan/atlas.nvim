local M = {}

---@type table<string, table>
local groups = {
	AtlasShortcutTheme = { fg = "#FFFFFF", bg = "#494BCB", bold = true },
	AtlasShortcutChipParent = { link = "AtlasShortcutTheme" },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
