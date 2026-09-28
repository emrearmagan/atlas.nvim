local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local threads = require("atlas.ui.components.threads")

local COLLAPSE_KEEP = 3
local COLLAPSE_THRESHOLD = 5

---@param items AtlasThreadItem[]
---@param width integer
---@param opts? { padding_x?: integer, content_max_lines?: integer, squash?: boolean, run_id?: string, has_next?: boolean, author_hl?: fun(item: AtlasThreadItem, author: string): string|nil, additional_hl?: fun(item: AtlasThreadItem, text: string): string|nil, content_hl?: fun(item: AtlasThreadItem, row: string, row_index: integer): table[]|nil }
---@return string[], table[], table<integer, table>
function M.render(items, width, opts)
	opts = opts or {}
	local padding_x = opts.padding_x or 1
	local lines, spans, line_map = {}, {}, {}

	local function append(sub_lines, sub_spans, sub_map)
		local base = #lines
		utils.append_block(lines, spans, { lines = sub_lines, highlights = sub_spans })
		for row, entry in pairs(sub_map or {}) do
			line_map[base + row] = entry
		end
	end

	local function separator()
		if #lines == 0 then
			return
		end
		local line = string.rep(" ", padding_x) .. "│"
		append({ line }, { { line = 0, start_col = padding_x, end_col = #line, hl_group = "AtlasTextMuted" } })
	end

	local function render_entry(item, has_next)
		separator()
		append(threads.render({ item }, width, {
			padding_x = padding_x,
			content_max_lines = opts.content_max_lines or 3,
			content_prefix = has_next and "│  " or "   ",
			author_hl = opts.author_hl,
			additional_hl = opts.additional_hl,
			content_hl = opts.content_hl,
		}))
	end

	local function render_gap(count)
		local text = string.format(
			"%s  ... %d more %s",
			icons.general("activity_more"),
			count,
			count == 1 and "activity" or "activities"
		)
		local line = string.rep(" ", padding_x) .. text
		append(
			{ line },
			{ { line = 0, start_col = padding_x, end_col = #line, hl_group = "AtlasTextMuted" } },
			opts.run_id and { [1] = { kind = "activity_gap", run_id = opts.run_id } } or nil
		)
	end

	local first = 1
	if opts.squash and #items > COLLAPSE_THRESHOLD then
		first = #items - COLLAPSE_KEEP + 1
		render_gap(first - 1)
	end
	for index = first, #items do
		render_entry(items[index], index < #items or opts.has_next == true)
	end

	return lines, spans, line_map
end

return M
