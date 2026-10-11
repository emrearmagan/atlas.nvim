local M = {}

local ui_utils = require("atlas.ui.utils")
local text_width = ui_utils.text_width

function M.render(opts)
	local width = opts.width or vim.o.columns
	local items = opts.items or {} -- { label, icon, active }
	local actions = opts.actions or {} -- { label, hl_group }
	local active_hl = opts.active_hl
	local inactive_hl = opts.inactive_hl or "AtlasTabInactive"

	local margin = 1
	local line = string.rep(" ", margin)
	local highlights = {}
	local byte_col = margin
	local display_col = margin

	for _, item in ipairs(items) do
		local label
		if item.icon and item.icon ~= "" then
			label = string.format(" %s  %s ", item.icon, item.label or "")
		else
			label = string.format(" %s ", item.label or "")
		end
		local hl = item.active and active_hl or inactive_hl

		line = line .. label .. "  "
		table.insert(highlights, {
			line = 0,
			start_col = byte_col,
			end_col = byte_col + #label,
			hl_group = hl,
		})

		byte_col = byte_col + #label + 2
		display_col = display_col + text_width(label) + 2
	end

	local actions_width = 0
	for i, action in ipairs(actions) do
		actions_width = actions_width + text_width(action.label)
		if i < #actions then
			actions_width = actions_width + 2
		end
	end

	local padding = width - display_col - actions_width - margin
	if padding > 0 then
		line = line .. string.rep(" ", padding)
		byte_col = byte_col + padding
	end

	for i, action in ipairs(actions) do
		line = line .. action.label
		table.insert(highlights, {
			line = 0,
			start_col = byte_col,
			end_col = byte_col + #action.label,
			hl_group = action.hl_group,
		})

		byte_col = byte_col + #action.label
		if i < #actions then
			line = line .. "  "
			byte_col = byte_col + 2
		end
	end

	return { lines = { line }, highlights = highlights }
end

return M
