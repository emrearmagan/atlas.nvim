local M = {}

local ui_utils = require("atlas.ui.utils")

function M.render(opts)
	local width = opts.width or vim.o.columns
	local icon = opts.icon or ""
	local title = opts.title or "Atlas"
	local hl_group = opts.hl_group or "Title"

	local text = string.format("  %s  %s  ", icon, title)
	local line, start_col = ui_utils.center_text(text, math.max(width - 2, 20))

	return {
		lines = { line, "" },
		highlights = {
			{ line = 0, start_col = start_col, end_col = start_col + #text, hl_group = hl_group },
		},
	}
end

return M
