local M = {}

---@param chips IssuesDetailChip[]
---@param opts { width: integer, padding_x?: integer }
---@return string[], table[]
local function render_chips(chips, opts)
	local pad = math.max(0, opts.padding_x or 1)
	local padding = string.rep(" ", pad)
	local width = math.max(1, opts.width)
	local lines = {}
	local line = padding
	local spans = {}
	local line_width = pad
	local has_chip = false

	for _, chip in ipairs(chips) do
		if chip ~= nil then
			local label = string.format(" %s ", chip.label)
			local gap = has_chip and " " or ""
			local next_width = line_width + vim.api.nvim_strwidth(gap .. label)
			if has_chip and next_width > width then
				table.insert(lines, line)
				line = padding
				line_width = pad
				gap = ""
				has_chip = false
			end

			line = line .. gap
			local start_col = #line
			line = line .. label
			if chip.hl ~= nil then
				table.insert(spans, {
					line = #lines,
					start_col = start_col,
					end_col = start_col + #label,
					hl_group = chip.hl,
				})
			end
			line_width = vim.api.nvim_strwidth(line)
			has_chip = true
		end
	end

	if has_chip then
		table.insert(lines, line)
	end
	return lines, spans
end

---@param opts { width: integer, padding_x?: integer, extra_chips?: IssuesDetailChip[] }
---@return string[], table[]
function M.render(opts)
	local chips = {}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	if #chips == 0 then
		return {}, {}
	end

	return render_chips(chips, opts)
end

return M
