local utils = require("atlas.ui.shared.utils")

local M = {}

---@class AtlasCodePreviewOptions
---@field file_path string|nil
---@field language string|nil Filetype or fence language; takes precedence over file_path.
---@field lines string[]
---@field start_line integer|nil Defaults to 1.
---@field anchor_line integer|nil
---@field anchor_start integer|nil
---@field line_numbers integer[]|nil
---@field show_line_numbers boolean|nil
---@field padding integer|nil Spaces on each side of the code; defaults to 0.
---@field width integer|nil Maximum width including padding for unnumbered blocks; numbered previews preserve source lines.
---@field background_hl_group string|nil Defaults to AtlasCodeBackground.

-- Highlight original code before wrapping or adding line numbers and padding.
local function syntax_highlights(lines, opts)
	local filetype = opts.language
	if filetype == nil and opts.file_path then
		filetype = vim.filetype.match({ filename = opts.file_path })
	end
	if not filetype or filetype == "" or #lines == 0 then
		return {}
	end

	local language = vim.treesitter.language.get_lang(filetype) or filetype
	local source = table.concat(lines, "\n")
	local parser = vim.treesitter.get_string_parser(source, language)
	local tree = parser:parse()[1]
	local query = vim.treesitter.query.get(language, "highlights")
	if not query then
		return {}
	end

	local highlights = {}
	for id, node, metadata in query:iter_captures(tree:root(), source) do
		local capture = query.captures[id]
		if capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" then
			local range = vim.treesitter.get_range(node, source, metadata and metadata[id])
			local start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
			local hl_group = "@" .. capture .. "." .. language

			for row = start_row, math.min(end_row, #lines - 1) do
				local from = row == start_row and start_col or 0
				local to = row == end_row and end_col or #lines[row + 1]
				if to > from then
					highlights[#highlights + 1] = {
						line = row,
						start_col = from,
						end_col = to,
						hl_group = hl_group,
					}
				end
			end
		end
	end

	return highlights
end

-- { lines = { "return 1" }, language = "lua", show_line_numbers = false, padding = 2 }
-- -> { lines = { "  return 1  " }, highlights = { ... } }.
---@param opts AtlasCodePreviewOptions
---@return { lines: string[], highlights: AtlasUIHighlight[], selection?: { first: integer, last: integer } }
function M.render(opts)
	local numbered = opts.show_line_numbers ~= false
	local width = not numbered and opts.width or nil
	local pad = opts.padding or 0
	if width then
		pad = math.min(pad, math.max(0, math.floor((width - 1) / 2)))
	end

	-- Keep the code visible if syntax highlighting fails.
	local ok, syntax = pcall(syntax_highlights, opts.lines, opts)
	local content = { lines = opts.lines, highlights = ok and syntax or {} }
	if width then
		content = utils.wrap_content(content, math.max(1, width - pad * 2), "")
	end

	local start_line = opts.start_line or 1
	local gutter_width = 0
	local number_format
	if numbered then
		local last_line = start_line + #opts.lines - 1
		for _, line in ipairs(opts.line_numbers or {}) do
			last_line = math.max(last_line, line)
		end

		local number_width = #tostring(last_line)
		number_format = "%" .. number_width .. "d  "
		gutter_width = number_width + 2
	end

	local padding = string.rep(" ", pad)
	local background = opts.background_hl_group or "AtlasCodeBackground"
	local lines, highlights = {}, {}
	for index, source in ipairs(content.lines) do
		lines[index] = padding .. source .. padding
		highlights[#highlights + 1] = {
			line = index - 1,
			line_hl_group = background,
		}

		if number_format then
			local line_number = start_line + index - 1
			local display_line = opts.line_numbers and opts.line_numbers[index] or line_number
			local selected = opts.anchor_line
				and line_number >= (opts.anchor_start or opts.anchor_line)
				and line_number <= opts.anchor_line

			lines[index] = string.format(number_format, display_line) .. lines[index]
			highlights[#highlights + 1] = {
				line = index - 1,
				start_col = 0,
				end_col = gutter_width,
				hl_group = selected and "CursorLineNr" or "AtlasTextMuted",
			}
		end
	end

	local offset = gutter_width + pad
	for _, span in ipairs(content.highlights) do
		span.start_col = span.start_col + offset
		span.end_col = span.end_col + offset
		highlights[#highlights + 1] = span
	end

	local selection
	if numbered and opts.anchor_line then
		selection = {
			first = (opts.anchor_start or opts.anchor_line) - start_line + 1,
			last = opts.anchor_line - start_line + 1,
		}
	end

	return { lines = lines, highlights = highlights, selection = selection }
end

return M
