local M = {}

local code_preview = require("atlas.ui.components.code_preview")
local utils = require("atlas.ui.shared.utils")

---@class AtlasDiffHunkRenderOptions
---@field max_width integer
---@field padding_x integer|nil                       default 1
---@field show_line_numbers boolean|nil

local DEFAULT_PADDING = 1

---@param file { path: string }
---@param hunk DiffHunk
---@return string
function M.hunk_key(file, hunk)
	return string.format("%s|%s|%s", file.path, tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
end

---@param file DiffFile
---@return integer additions, integer deletions
function M.file_stats(file)
	if file.additions ~= nil or file.deletions ~= nil then
		return file.additions or 0, file.deletions or 0
	end
	local a, d = 0, 0
	for _, hunk in ipairs(file.hunks or {}) do
		a = a + (hunk.additions or 0)
		d = d + (hunk.deletions or 0)
	end
	return a, d
end

---@param lines string[]
---@param spans table[]
---@param file DiffFile
---@param padding_x integer
---@param max_width integer
local function emit_file_header(lines, spans, file, padding_x, max_width)
	local label = file.path
	if file.status == "renamed" and file.old_path then
		label = file.old_path .. " → " .. file.path
	end

	label = utils.truncate(label, math.max(1, max_width - padding_x - 4), true)
	local prefix = string.rep(" ", padding_x) .. label .. " "
	local text = prefix .. string.rep("─", math.max(0, max_width - vim.api.nvim_strwidth(prefix)))

	table.insert(lines, text)
	local lnum = #lines - 1
	table.insert(spans, { line = lnum, start_col = padding_x, end_col = padding_x + #label, hl_group = "Normal" })
	table.insert(spans, { line = lnum, start_col = #prefix, end_col = #text, hl_group = "AtlasTextMuted" })
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param file DiffFile
---@param hunk DiffHunk
---@param opts AtlasDiffHunkRenderOptions
local function render_hunk(lines, spans, line_map, file, hunk, opts)
	local padding_x = opts.padding_x or DEFAULT_PADDING
	local pad = string.rep(" ", padding_x)
	local key = M.hunk_key(file, hunk)

	---@param row string
	---@param hl_full string|nil
	---@param segments table[]|nil
	local function push(row, hl_full, segments)
		local text = pad .. row
		table.insert(lines, text)
		local lnum = #lines - 1
		if hl_full then
			table.insert(spans, { line = lnum, line_hl_group = hl_full })
		end
		for _, seg in ipairs(segments or {}) do
			table.insert(spans, { line = lnum, start_col = #pad + seg[1], end_col = #pad + seg[2], hl_group = seg[3] })
		end
		return lnum
	end

	local source_lines, line_numbers = {}, {}
	for _, dl in ipairs(hunk.lines or {}) do
		if dl.kind ~= "meta" then
			local line = dl.new_line or dl.old_line or 0
			table.insert(source_lines, dl.content or dl.text or "")
			table.insert(line_numbers, line)
		end
	end
	local preview = code_preview.render({
		file_path = file.path,
		lines = source_lines,
		start_line = 1,
		anchor_line = nil,
		line_numbers = line_numbers,
		show_line_numbers = opts.show_line_numbers,
	})
	local preview_spans, preview_backgrounds = {}, {}
	for _, span in ipairs(preview.highlights) do
		if span.hl_group then
			preview_spans[span.line + 1] = preview_spans[span.line + 1] or {}
			table.insert(preview_spans[span.line + 1], { span.start_col, span.end_col, span.hl_group })
		elseif span.line_hl_group then
			preview_backgrounds[span.line + 1] = span.line_hl_group
		end
	end
	local preview_index = 0
	for _, dl in ipairs(hunk.lines or {}) do
		if dl.kind == "meta" then
			local text = dl.content or dl.text or ""
			push(" " .. text, nil, { { 0, #(" " .. text), "AtlasTextMuted" } })
		else
			preview_index = preview_index + 1
			local marker = dl.kind == "add" and "+ " or (dl.kind == "remove" and "- " or "  ")
			local text = marker .. preview.lines[preview_index]
			local highlights = {}
			for _, highlight in ipairs(preview_spans[preview_index] or {}) do
				table.insert(highlights, {
					highlight[1] + #marker,
					highlight[2] + #marker,
					highlight[3],
				})
			end
			if dl.kind == "add" or dl.kind == "remove" then
				table.insert(highlights, {
					0,
					1,
					dl.kind == "add" and "AtlasTextPositive" or "AtlasLogError",
				})
			end

			local body_lnum
			if dl.kind == "add" then
				body_lnum = push(text, "AtlasDiffAddLine", highlights)
			elseif dl.kind == "remove" then
				body_lnum = push(text, "AtlasDiffRemoveLine", highlights)
			else
				body_lnum = push(text, preview_backgrounds[preview_index], highlights)
			end
			line_map[body_lnum + 1] = {
				kind = "hunk_line",
				path = file.path,
				side = dl.kind == "remove" and "old" or "new",
				line = dl.new_line or dl.old_line,
				hunk_key = key,
				hunk_start = preview_index == 1,
			}
		end
	end
end

---@param files DiffFile[]
---@param opts AtlasDiffHunkRenderOptions
---@return string[], table[], table<integer, table>
function M.hunks(files, opts)
	local padding_x = opts.padding_x or DEFAULT_PADDING
	local lines = {}
	local spans = {}
	local line_map = {}

	for fi, file in ipairs(files) do
		emit_file_header(lines, spans, file, padding_x, opts.max_width)

		for hi, hunk in ipairs(file.hunks) do
			if hi > 1 then
				local separator = string.rep(" ", padding_x) .. "..."
				table.insert(lines, separator)
				table.insert(spans, {
					line = #lines - 1,
					start_col = padding_x,
					end_col = #separator,
					hl_group = "AtlasTextMuted",
				})
			end
			render_hunk(lines, spans, line_map, file, hunk, opts)
		end

		if fi < #files then
			table.insert(lines, "")
		end
	end

	return lines, spans, line_map
end

return M
