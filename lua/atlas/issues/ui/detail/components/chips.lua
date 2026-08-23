local M = {}

---@param chips IssuesDetailChip[]
---@param opts { padding_x?: integer }|nil
---@return string, table[]
local function render_chips(chips, opts)
	opts = opts or {}
	local pad = math.max(0, opts.padding_x or 1)
	local line = string.rep(" ", pad)
	local spans = {}
	local col = pad

	for _, chip in ipairs(chips) do
		if chip ~= nil then
			local label = string.format(" %s ", chip.label)
			line = line .. label .. " "
			if chip.hl ~= nil then
				table.insert(spans, {
					start_col = col,
					end_col = col + #label,
					hl_group = chip.hl,
				})
			end
			col = col + #label + 1
		end
	end

	return line, spans
end

---@param opts { padding_x?: integer, extra_chips?: IssuesDetailChip[] }|nil
---@return string, table[]
function M.render(opts)
	opts = opts or {}
	local chips = {}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	if #chips == 0 then
		return "", {}
	end

	return render_chips(chips, opts)
end

return M
