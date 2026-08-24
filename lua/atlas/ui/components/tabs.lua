local utils = require("atlas.ui.shared.utils")

local M = {}

---@param items { key: string, label: string, icon: string|nil, icon_hl: string|nil }[]
---@param active_tab string
---@param width integer
---@param opts? { inactive_hl?: string, active_hl?: string, gap?: string, divider_hl?: string, padding_x?: integer }
---@return string[] lines
---@return table[] spans
function M.render(items, active_tab, width, opts)
	opts = opts or {}
	local inactive_hl = opts.inactive_hl or "AtlasTextMuted"
	local active_hl = opts.active_hl
	local gap = opts.gap or " "
	local padding_x = math.max(0, tonumber(opts.padding_x) or 0)
	local padding = string.rep(" ", padding_x)

	local available = math.max(1, width - padding_x)
	local line = ""
	local spans = {}
	local col = 0

	for i, tab in ipairs(items or {}) do
		local icon = type(tab.icon) == "string" and tab.icon ~= "" and (tab.icon .. " ") or ""
		local part = string.format("%s%s ", icon, tab.label or "")
		line = line .. part

		---@type string|nil
		local hl = inactive_hl
		if tab.key == active_tab then
			hl = active_hl
		end
		if type(hl) == "string" and hl ~= "" then
			table.insert(spans, {
				line = 0,
				start_col = col,
				end_col = col + #part,
				hl_group = hl,
			})
		end
		col = col + #part

		if i < #items then
			line = line .. gap
			col = col + #gap
		end
	end

	if vim.api.nvim_strwidth(line) > available then
		line = utils.truncate(line, available)
	end
	local visible_spans = {}
	for _, span in ipairs(spans) do
		span.end_col = math.min(span.end_col, #line)
		if span.start_col < span.end_col then
			table.insert(visible_spans, span)
		end
	end
	spans = visible_spans

	local lines = { padding .. line }
	if padding_x > 0 then
		for _, span in ipairs(spans) do
			if (span.line or 0) == 0 then
				span.start_col = span.start_col + padding_x
				span.end_col = span.end_col + padding_x
			end
		end
	end
	local divider = string.rep("─", math.max(1, width))
	table.insert(lines, divider)
	table.insert(spans, {
		line = 1,
		start_col = 0,
		end_col = #divider,
		hl_group = opts.divider_hl or "AtlasTextMuted",
	})

	return lines, spans
end

return M
