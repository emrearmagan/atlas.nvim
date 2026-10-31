local icons = require("atlas.ui.shared.icons")
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local M = {}

---@param win integer|nil
---@param path string
function M.set(win, path)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local parts = vim.split(path, "/", { plain = true })
	local breadcrumbs = {}
	for index, name in ipairs(parts) do
		local icon, highlight = icons.get("folder_open")
		if index == #parts then
			icon, highlight = icons.get("file")
			if has_devicons then
				local glyph, group = devicons.get_icon(name, nil, { default = true })
				icon, highlight = glyph or icon, group or highlight
			end
		end

		breadcrumbs[#breadcrumbs + 1] = string.format("%%#%s#%s %%#Normal#%s", highlight, icon, name:gsub("%%", "%%%%"))
	end

	local separator, highlight = icons.get("fold_closed")
	vim.wo[win].winbar = "%#Normal# " .. table.concat(breadcrumbs, string.format("%%#%s# %s ", highlight, separator))
end

---@param renderer AtlasDiffRenderer
function M.update(renderer)
	local file = renderer.current_file
	if not file then
		return
	end

	M.set(renderer.right.win, file.path)
	M.set(renderer.left.win, file.old_path or file.path)
end

return M
