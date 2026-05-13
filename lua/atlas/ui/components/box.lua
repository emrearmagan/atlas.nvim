local M = {}

local BORDER_TOP_LEFT = "╭"
local BORDER_TOP_RIGHT = "╮"
local BORDER_BOTTOM_LEFT = "╰"
local BORDER_BOTTOM_RIGHT = "╯"
local BORDER_HORIZONTAL = "─"
local BORDER_VERTICAL = "│"

local BORDER_V_BYTES = #BORDER_VERTICAL

---@class BoxContentGroup
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>|nil

---@class BoxRenderOpts
---@field width integer
---@field padding_x integer|nil
---@field border_hl string|nil
---@field line_map table<integer, table>|nil
---@field line_offset integer|nil

---@param groups BoxContentGroup[]
---@param opts BoxRenderOpts
---@return { lines: string[], highlights: table[], line_map: table<integer, table> }
function M.render(groups, opts)
	local padding_x = opts.padding_x or 1
	local border_hl = opts.border_hl or "AtlasBorder"
	local outer_pad = string.rep(" ", padding_x)

	local inner_width = math.max(4, opts.width - (padding_x * 2) - 2)

	local lines = {}
	local highlights = {}
	local line_map = {}

	local function add_border_hl(lnum, line)
		table.insert(highlights, {
			line = lnum,
			start_col = padding_x,
			end_col = #line,
			hl_group = border_hl,
		})
	end

	-- Top border
	local top = outer_pad .. BORDER_TOP_LEFT .. string.rep(BORDER_HORIZONTAL, inner_width) .. BORDER_TOP_RIGHT
	table.insert(lines, top)
	add_border_hl(#lines - 1, top)

	for gi, group in ipairs(groups) do
		if gi > 1 then
			-- Separator between groups
			local sep = outer_pad
				.. BORDER_VERTICAL
				.. " "
				.. string.rep(BORDER_HORIZONTAL, inner_width - 2)
				.. " "
				.. BORDER_VERTICAL
			table.insert(lines, sep)
			add_border_hl(#lines - 1, sep)
		end

		local col_shift = padding_x + BORDER_V_BYTES + 1

		for _, content_line in ipairs(group.lines or {}) do
			local padded = " " .. content_line
			local display_width = vim.api.nvim_strwidth(padded)
			if display_width < inner_width then
				padded = padded .. string.rep(" ", inner_width - display_width)
			end
			local line = outer_pad .. BORDER_VERTICAL .. padded .. BORDER_VERTICAL
			table.insert(lines, line)
			local lnum = #lines - 1
			-- Left border
			table.insert(highlights, {
				line = lnum,
				start_col = padding_x,
				end_col = padding_x + BORDER_V_BYTES,
				hl_group = border_hl,
			})
			-- Right border
			table.insert(highlights, {
				line = lnum,
				start_col = #line - BORDER_V_BYTES,
				end_col = #line,
				hl_group = border_hl,
			})
		end

		-- Rebase content spans and line_map
		local line_offset = #lines - #(group.lines or {})
		for _, span in ipairs(group.spans or {}) do
			table.insert(highlights, {
				line = line_offset + span.line,
				start_col = col_shift + span.start_col,
				end_col = col_shift + span.end_col,
				hl_group = span.hl_group,
			})
		end
		local target_map = opts.line_map or line_map
		local map_base = opts.line_map and (opts.line_offset or 0) or 0
		for lnum, entry in pairs(group.line_map or {}) do
			target_map[map_base + line_offset + lnum] = entry
		end
	end

	-- Bottom border
	local bottom = outer_pad .. BORDER_BOTTOM_LEFT .. string.rep(BORDER_HORIZONTAL, inner_width) .. BORDER_BOTTOM_RIGHT
	table.insert(lines, bottom)
	add_border_hl(#lines - 1, bottom)

	return { lines = lines, highlights = highlights, line_map = line_map }
end

return M
