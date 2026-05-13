local M = {}

local utils = require("atlas.ui.shared.utils")

---@class ChangesBlockOpts
---@field max_width integer
---@field padding_x integer|nil                       default 1
---@field collapsed_hunks table<string, boolean>|nil  key = path|new_start|old_start
---@field hunk_footer (fun(file: DiffFile, hunk: DiffHunk): string|nil)|nil

local DEFAULT_PADDING = 1

---@param file DiffFile
---@param hunk DiffHunk
---@return string
function M.hunk_key(file, hunk)
	return string.format("%s|%s|%s", file.path, tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
end

---@param file DiffFile
---@return integer additions, integer deletions
local function file_stats(file)
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
	local additions, deletions = file_stats(file)

	local label = file.path
	if file.status == "renamed" and file.old_path then
		label = file.old_path .. " → " .. file.path
	end

	local add_text = string.format("+%d", additions)
	local del_text = string.format("-%d", deletions)
	local sep = "  "
	local stats = add_text .. " " .. del_text

	local available = math.max(1, max_width - padding_x - vim.api.nvim_strwidth(sep .. stats))
	local truncated_label = utils.truncate(label, available, true)
	local text = string.rep(" ", padding_x) .. truncated_label .. sep .. stats

	table.insert(lines, text)
	local lnum = #lines - 1

	local label_start = padding_x
	local label_end = label_start + #truncated_label
	table.insert(spans, { line = lnum, start_col = label_start, end_col = label_end, hl_group = "Normal" })

	local add_start = label_end + #sep
	local add_end = add_start + #add_text
	table.insert(spans, {
		line = lnum,
		start_col = add_start,
		end_col = add_end,
		hl_group = additions > 0 and "AtlasTextPositive" or "AtlasTextMuted",
	})

	local del_start = add_end + 1
	local del_end = del_start + #del_text
	table.insert(spans, {
		line = lnum,
		start_col = del_start,
		end_col = del_end,
		hl_group = deletions > 0 and "AtlasLogError" or "AtlasTextMuted",
	})
end

---@param hunk DiffHunk
---@return integer
local function body_count(hunk)
	local n = 0
	for _, dl in ipairs(hunk.lines or {}) do
		if dl.kind ~= "meta" then
			n = n + 1
		end
	end
	return n
end

---@param hunk DiffHunk
---@return integer
local function gutter_width(hunk)
	local max_num =
		math.max((hunk.old_start or 0) + (hunk.old_count or 0), (hunk.new_start or 0) + (hunk.new_count or 0))
	return math.max(2, #tostring(max_num))
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param file DiffFile
---@param hunk DiffHunk
---@param is_collapsed boolean
---@param opts ChangesBlockOpts
local function render_hunk(lines, spans, line_map, file, hunk, is_collapsed, opts)
	local padding_x = opts.padding_x or DEFAULT_PADDING
	local pad = string.rep(" ", padding_x)
	local inner = math.max(20, opts.max_width - (padding_x * 2))
	local key = M.hunk_key(file, hunk)

	---@param row string
	---@param hl_full string|nil
	---@param segments table[]|nil
	local function push(row, hl_full, segments)
		local dw = vim.api.nvim_strwidth(row)
		if dw < inner then
			row = row .. string.rep(" ", inner - dw)
		end
		local text = pad .. row
		table.insert(lines, text)
		local lnum = #lines - 1
		if hl_full then
			table.insert(spans, { line = lnum, start_col = #pad, end_col = #text, hl_group = hl_full })
		end
		for _, seg in ipairs(segments or {}) do
			table.insert(spans, { line = lnum, start_col = #pad + seg[1], end_col = #pad + seg[2], hl_group = seg[3] })
		end
		return lnum
	end

	-- Header
	local header_text = hunk.header or ""
	local suffix = ""
	if is_collapsed and header_text ~= "" then
		suffix = string.format("  [+%d lines]", body_count(hunk))
	end
	local leading = " "
	local available = math.max(1, inner - vim.api.nvim_strwidth(leading .. suffix))
	header_text = utils.truncate(header_text, available)
	local hdr_str = leading .. header_text .. suffix
	local hdr_lnum = push(hdr_str, nil, { { 0, #hdr_str, "AtlasTextMuted" } })
	line_map[hdr_lnum + 1] = { kind = "hunk_header", path = file.path, hunk_key = key }

	-- Body
	if not is_collapsed then
		local gw = gutter_width(hunk)
		for _, dl in ipairs(hunk.lines or {}) do
			if dl.kind == "meta" then
				local text = dl.content or dl.text or ""
				push(" " .. text, nil, { { 0, #(" " .. text), "AtlasTextMuted" } })
			else
				local num = dl.new_line or dl.old_line or 0
				local num_str = num > 0 and tostring(num) or ""
				num_str = string.rep(" ", gw - #num_str) .. num_str
				local marker = dl.kind == "add" and "+" or (dl.kind == "remove" and "-" or " ")
				local content = dl.content or dl.text or ""
				local prefix = " " .. num_str .. " " .. marker .. " "
				local text = prefix .. content

				local body_lnum
				if dl.kind == "add" then
					body_lnum = push(text, "AtlasDiffAddLine", { { 0, #prefix, "AtlasDiffAddMarker" } })
				elseif dl.kind == "remove" then
					body_lnum = push(text, "AtlasDiffRemoveLine", { { 0, #prefix, "AtlasDiffRemoveMarker" } })
				else
					body_lnum = push(text, nil, {
						{ 0, #prefix, "AtlasTextMuted" },
						{ #prefix, #text, "AtlasDiffContext" },
					})
				end
				line_map[body_lnum + 1] = {
					kind = "hunk_line",
					path = file.path,
					side = dl.kind == "remove" and "old" or "new",
					line = dl.new_line or dl.old_line,
				}
			end
		end
	end

	-- Bottom
	local footer = opts.hunk_footer and opts.hunk_footer(file, hunk) or nil
	local bottom_text
	local label = (footer and footer ~= "") and ("└─ " .. footer .. " ") or "└─"
	local fill_w = math.max(1, inner - vim.api.nvim_strwidth(label))
	bottom_text = pad .. label .. string.rep("─", fill_w)
	table.insert(lines, bottom_text)
	table.insert(spans, {
		line = #lines - 1,
		start_col = #pad,
		end_col = #bottom_text,
		hl_group = "AtlasTextMuted",
	})
end

---@param files DiffFile[]
---@param opts ChangesBlockOpts
---@return string[], table[], table<integer, table>
function M.render(files, opts)
	local padding_x = opts.padding_x or DEFAULT_PADDING
	local lines = {}
	local spans = {}
	local line_map = {}

	for fi, file in ipairs(files) do
		if file.hunks and #file.hunks > 0 then
			emit_file_header(lines, spans, file, padding_x, opts.max_width)
			table.insert(lines, "")

			for hi, hunk in ipairs(file.hunks) do
				local key = M.hunk_key(file, hunk)
				local is_collapsed = (opts.collapsed_hunks or {})[key] == true
				render_hunk(lines, spans, line_map, file, hunk, is_collapsed, opts)
				if hi < #file.hunks then
					table.insert(lines, "")
				end
			end

			if fi < #files then
				table.insert(lines, "")
			end
		end
	end

	return lines, spans, line_map
end

return M
