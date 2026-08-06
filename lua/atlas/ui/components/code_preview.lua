local M = {}

---@class AtlasCodePreviewOptions
---@field file_path string
---@field lines string[]
---@field start_line integer
---@field anchor_line integer|nil
---@field anchor_start integer|nil
---@field prefixes string[]|nil

---@param opts AtlasCodePreviewOptions
---@return AtlasMarkdownEditorPreview
function M.render(opts)
	local last_line = opts.start_line + #opts.lines - 1
	local number_width = #tostring(last_line)
	local lines, prefixes, highlights = {}, {}, {}
	for index, source in ipairs(opts.lines) do
		local line_number = opts.start_line + index - 1
		local selected = opts.anchor_start
				and opts.anchor_line
				and line_number >= opts.anchor_start
				and line_number <= opts.anchor_line
			or line_number == opts.anchor_line
		local prefix = opts.prefixes and opts.prefixes[index]
			or string.format("%" .. number_width .. "d  ", line_number)
		prefixes[index] = #prefix
		table.insert(lines, prefix .. source)
		table.insert(highlights, {
			line = index - 1,
			line_hl_group = "AtlasFooterBackground",
		})
		table.insert(highlights, {
			line = index - 1,
			start_col = 0,
			end_col = #prefix,
			hl_group = selected and "CursorLineNr" or "AtlasTextMuted",
		})
	end

	local ok, syntax = pcall(function()
		local filetype = vim.filetype.match({ filename = opts.file_path })
		local language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
		if not language then
			return {}
		end

		local source = table.concat(opts.lines, "\n")
		local parser = vim.treesitter.get_string_parser(source, language)
		local tree = parser:parse()[1]
		local query = vim.treesitter.query.get(language, "highlights")
		if not tree or not query then
			return {}
		end

		local syntax_highlights = {}
		for id, node in query:iter_captures(tree:root(), source) do
			local capture = query.captures[id]
			if capture and capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" then
				local start_row, start_col, end_row, end_col = node:range()
				for row = start_row, math.min(end_row, #opts.lines - 1) do
					local from = row == start_row and start_col or 0
					local to = row == end_row and end_col or #(opts.lines[row + 1] or "")
					if to > from then
						table.insert(syntax_highlights, {
							line = row,
							start_col = prefixes[row + 1] + from,
							end_col = prefixes[row + 1] + to,
							hl_group = "@" .. capture .. "." .. language,
						})
					end
				end
			end
		end
		return syntax_highlights
	end)
	if ok then
		vim.list_extend(highlights, syntax)
	end
	return { lines = lines, highlights = highlights }
end

return M
