local M = {}
local utils = require("atlas.ui.shared.utils")

-- Neovim can load these parsers before a plugin registers their filetype aliases.
local parser_aliases = {
	sh = "bash",
	javascriptreact = "javascript",
	typescriptreact = "tsx",
	tex = "latex",
	cs = "c_sharp",
}

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
	if opts.language and language == filetype then
		filetype = vim.filetype.match({ filename = "code." .. opts.language }) or filetype
		language = vim.treesitter.language.get_lang(filetype) or filetype
	end
	if language == filetype then
		language = parser_aliases[filetype] or language
	end
	local source = table.concat(lines, "\n")
	local ok, parser = pcall(vim.treesitter.get_string_parser, source, language)
	if not ok then
		return {}
	end
	local tree = parser:parse()[1]
	local query = vim.treesitter.query.get(language, "highlights")
	if not tree or not query then
		return {}
	end

	local highlights = {}
	for id, node, metadata in query:iter_captures(tree:root(), source) do
		local capture = query.captures[id]
		if capture and capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" then
			local range = vim.treesitter.get_range(node, source, metadata and metadata[id])
			local start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
			for row = start_row, math.min(end_row, #lines - 1) do
				local from = row == start_row and start_col or 0
				local to = row == end_row and end_col or #lines[row + 1]
				if to > from then
					table.insert(highlights, {
						line = row,
						start_col = from,
						end_col = to,
						hl_group = "@" .. capture .. "." .. language,
					})
				end
			end
		end
	end
	return highlights
end

-- { lines = { "return 1" }, language = "lua", show_line_numbers = false, padding = 2 }
-- -> { lines = { "  return 1  " }, highlights = { ... } }.
---@param opts AtlasCodePreviewOptions
---@return { lines: string[], highlights: AtlasUIHighlight[] }
function M.render(opts)
	local width = opts.show_line_numbers == false and opts.width or nil
	local pad = opts.padding or 0
	if width then
		pad = math.min(pad, math.max(0, math.floor((width - 1) / 2)))
	end
	local content = { lines = opts.lines, highlights = syntax_highlights(opts.lines, opts) }
	if width then
		content = utils.wrap_content(content, math.max(1, width - pad * 2), "")
	end

	local start_line = opts.start_line or 1
	local last_line = start_line + #opts.lines - 1
	for _, line in ipairs(opts.line_numbers or {}) do
		last_line = math.max(last_line, line)
	end
	local number_width = #tostring(last_line)
	local gutter_width = opts.show_line_numbers == false and 0 or number_width + 2
	local padding = string.rep(" ", pad)
	local lines, highlights = {}, {}
	for index, source in ipairs(content.lines) do
		local line_number = start_line + index - 1
		local selected = opts.anchor_start
				and opts.anchor_line
				and line_number >= opts.anchor_start
				and line_number <= opts.anchor_line
			or line_number == opts.anchor_line
		local display_line = opts.line_numbers and opts.line_numbers[index] or line_number
		local prefix = opts.show_line_numbers == false and ""
			or string.format("%" .. number_width .. "d  ", display_line)
		table.insert(lines, prefix .. padding .. source .. padding)
		table.insert(highlights, {
			line = index - 1,
			line_hl_group = opts.background_hl_group or "AtlasCodeBackground",
		})
		if gutter_width > 0 then
			table.insert(highlights, {
				line = index - 1,
				start_col = 0,
				end_col = gutter_width,
				hl_group = selected and "CursorLineNr" or "AtlasTextMuted",
			})
		end
	end
	for _, span in ipairs(content.highlights) do
		table.insert(highlights, {
			line = span.line,
			start_col = gutter_width + pad + span.start_col,
			end_col = gutter_width + pad + span.end_col,
			hl_group = span.hl_group,
		})
	end
	return { lines = lines, highlights = highlights }
end

return M
