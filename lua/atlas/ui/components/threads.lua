local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")
local markdown = require("atlas.formats.markdown")

---@alias AtlasThreadMode "tree" | "linked"

---@class AtlasThreadFooterItem
---@field text string
---@field hl_group string|nil
---@field highlights { start_col: integer, end_col: integer, hl_group: string }[]|nil

---@class AtlasThreadItem
---@field icon string|nil Icon string rendered before author
---@field icon_hl string|nil Highlight group for the icon
---@field author string|nil Display name of the author
---@field additional string|nil Extra text between author and timestamp
---@field right_text string|nil Right-aligned text (e.g. timestamp, hash)
---@field content string|nil Body text (may contain newlines)
---@field markdown boolean|nil
---@field language string|nil
---@field file_path string|nil
---@field language_aliases table<string, string>|nil
---@field footer_items AtlasThreadFooterItem[]|nil
---@field children AtlasThreadItem[]|nil Nested replies
---@field meta table|nil Arbitrary metadata passed through
---@field line_map table|nil Extra fields merged into every line-map entry

---@class AtlasThreadRenderOpts
---@field padding_x integer|nil Horizontal padding (default 2)
---@field mode AtlasThreadMode|nil Rendering mode (default "tree")
---@field show_connectors boolean|nil Show tree connectors (default true)
---@field separator string|nil Character for root separators (default "─")
---@field content_max_lines integer|fun(item: AtlasThreadItem): integer|nil Max visible content lines per item (nil = unlimited).
---@field content_truncated_key string|nil Key shown when expandable content is truncated.
---@field content_prefix string|nil Prefix placed before root content after padding
---@field author_hl? fun(item: AtlasThreadItem, author: string): string|nil Returns hl group for author
---@field additional_hl? fun(item: AtlasThreadItem, additional: string): string|table[]|nil Returns a group or highlighted segments
---@field content_hl? fun(item: AtlasThreadItem, row: string, row_index: integer): table[]|nil Returns segments for content
---@field right_text_hl? fun(item: AtlasThreadItem, text: string): string|table[]|nil Returns hl group or {start_col,end_col,hl_group}[] segments for right_text
---@field icon_hl_fn (fun(item: AtlasThreadItem): string|nil)|nil Override icon highlight

---@class AtlasThreadSpan
---@field line integer 0-indexed line number
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@class AtlasThreadLineMap
---@field kind string
---@field item AtlasThreadItem
---@field [string] any

---@param item AtlasThreadItem
---@param part string
---@param depth integer
---@return AtlasThreadLineMap
local function make_line_map(item, part, depth)
	local kind = part
	if depth > 0 then
		kind = "thread_" .. part
	end

	---@type AtlasThreadLineMap
	local map = { kind = kind, item = item }

	if type(item.line_map) == "table" then
		for k, v in pairs(item.line_map) do
			if k ~= "kind" then
				map[k] = v
			end
		end
	end

	return map
end

---@param spans AtlasThreadSpan[]
---@param line integer 0-indexed
---@param start_col integer
---@param end_col integer
---@param hl_group string
local function span(spans, line, start_col, end_col, hl_group)
	spans[#spans + 1] = {
		line = line,
		start_col = start_col,
		end_col = end_col,
		hl_group = hl_group,
	}
end

---@param content { lines: string[], highlights?: AtlasUIHighlight[] }
---@param width integer
---@param prefix string
---@return { lines: string[], highlights: AtlasUIHighlight[] }
local function wrap_content(content, width, prefix)
	local lines, spans = {}, {}
	local highlights_by_line = {}

	for _, highlight in ipairs(content.highlights or {}) do
		local line = highlight.line + 1
		highlights_by_line[line] = highlights_by_line[line] or {}
		table.insert(highlights_by_line[line], highlight)
	end

	for index, source in ipairs(content.lines) do
		local rows, offsets = utils.wrap_line(source, width)
		for row_index, row in ipairs(rows) do
			local offset = offsets[row_index]
			table.insert(lines, prefix .. row)

			if prefix ~= "" then
				span(spans, #lines - 1, 0, #prefix, "AtlasTextMuted")
			end

			for _, highlight in ipairs(highlights_by_line[index] or {}) do
				local start_col = math.max(0, highlight.start_col - offset)
				local end_col = math.min(highlight.end_col - offset, #row)
				if end_col > start_col then
					span(spans, #lines - 1, #prefix + start_col, #prefix + end_col, highlight.hl_group)
				end
			end
		end
	end

	return { lines = lines, highlights = spans }
end

---@param _ AtlasThreadItem
---@param author string
---@return string
local function default_author_hl(_, author)
	local normalized = vim.trim(author):lower()
	if normalized == "" or normalized == "unknown" or normalized == "none" or normalized == "unassigned" then
		return "AtlasTextMuted"
	end

	return highlights.dynamic_for(normalized)
end

---@return nil
local function noop_hl()
	return nil
end

-- Prefix computation

---@class AtlasThreadPrefixes
---@field pad string Left padding
---@field continuation string │  or "   " or ""
---@field meta_prefix string Full prefix for the header line
---@field body_prefix string Full prefix for content/footer lines

---@param depth integer
---@param branch_prefix string
---@param is_last boolean
---@param padding_x integer
---@param show_connectors boolean
---@return AtlasThreadPrefixes
local function compute_prefixes(depth, branch_prefix, is_last, padding_x, show_connectors)
	local pad = string.rep(" ", padding_x)
	local connector = ""
	local continuation = ""

	if depth > 0 then
		if show_connectors then
			connector = is_last and "└─ " or "├─ "
			continuation = is_last and "   " or "│  "
		else
			connector = "   "
			continuation = "   "
		end
	end

	local meta_prefix = pad .. branch_prefix .. connector
	local body_prefix = depth == 0 and pad or (pad .. branch_prefix .. continuation)

	return {
		pad = pad,
		continuation = continuation,
		meta_prefix = meta_prefix,
		body_prefix = body_prefix,
	}
end

-- Header rendering

---@param lines string[]
---@param spans AtlasThreadSpan[]
---@param line_map table<integer, AtlasThreadLineMap>
---@param item AtlasThreadItem
---@param depth integer
---@param pfx AtlasThreadPrefixes
---@param opts AtlasThreadRenderOpts
---@param width integer
local function render_header(lines, spans, line_map, item, depth, pfx, opts, width)
	local parts = {}
	local col_markers = {} -- { {start, end, hl} }

	local cursor = #pfx.meta_prefix

	local icon = item.icon or ""
	if icon ~= "" then
		local icon_start = cursor
		parts[#parts + 1] = icon .. " "
		cursor = cursor + #icon + 1
		local hl = item.icon_hl
		if opts.icon_hl_fn then
			hl = opts.icon_hl_fn(item) or hl
		end
		if hl then
			col_markers[#col_markers + 1] = { icon_start, icon_start + #icon, hl }
		end
	end

	local author = tostring(item.author or "")
	if author == "" then
		author = "Unknown"
	end
	local author_start = cursor
	parts[#parts + 1] = author
	cursor = cursor + #author
	local author_hl_val = opts.author_hl(item, author)
	if type(author_hl_val) == "string" and author_hl_val ~= "" then
		col_markers[#col_markers + 1] = { author_start, cursor, author_hl_val }
	end

	local right_text = tostring(item.right_text or "")
	local right_text_dw = right_text ~= "" and (2 + vim.api.nvim_strwidth(right_text)) or 0

	local additional = tostring(item.additional or "")
	if additional ~= "" then
		local padding_x = opts.padding_x
		local used_dw = vim.api.nvim_strwidth(pfx.meta_prefix .. table.concat(parts, ""))
		local available = width - padding_x - used_dw - 2 - right_text_dw
		if available > 0 then
			local add_dw = vim.api.nvim_strwidth(additional)
			if add_dw > available then
				additional = utils.truncate(additional, available)
			end
		end

		parts[#parts + 1] = "  " .. additional
		cursor = cursor + 2
		local add_start = cursor
		cursor = cursor + #additional
		local add_hl = opts.additional_hl(item, additional)
		if type(add_hl) == "table" then
			for _, seg in ipairs(add_hl) do
				local end_col = math.min(seg.end_col, #additional)
				if seg.start_col < end_col then
					col_markers[#col_markers + 1] = {
						add_start + seg.start_col,
						add_start + end_col,
						seg.hl_group,
					}
				end
			end
		elseif type(add_hl) == "string" and add_hl ~= "" then
			col_markers[#col_markers + 1] = { add_start, cursor, add_hl }
		end
	end

	if right_text ~= "" then
		-- Align by display columns; highlights still use byte offsets.
		local content_so_far = pfx.meta_prefix .. table.concat(parts, "")
		local display_so_far = vim.api.nvim_strwidth(content_so_far)
		local display_rt = vim.api.nvim_strwidth(right_text)
		local right_edge = width - opts.padding_x
		local needed = math.max(2, right_edge - display_so_far - display_rt)
		parts[#parts + 1] = string.rep(" ", needed) .. right_text
		local rt_byte_start = #content_so_far + needed
		local hl = opts.right_text_hl and opts.right_text_hl(item, right_text) or nil
		if type(hl) == "table" then
			for _, seg in ipairs(hl) do
				col_markers[#col_markers + 1] = {
					rt_byte_start + seg.start_col,
					rt_byte_start + seg.end_col,
					seg.hl_group,
				}
			end
		else
			local group = type(hl) == "string" and hl or "AtlasTextMuted"
			col_markers[#col_markers + 1] = { rt_byte_start, rt_byte_start + #right_text, group }
		end
	end

	local full_line = pfx.meta_prefix .. table.concat(parts, "")
	lines[#lines + 1] = full_line
	line_map[#lines] = make_line_map(item, "header", depth)

	if #pfx.meta_prefix > 0 then
		span(spans, #lines - 1, 0, #pfx.meta_prefix, "AtlasTextMuted")
	end

	for _, m in ipairs(col_markers) do
		span(spans, #lines - 1, m[1], m[2], m[3])
	end
end

-- Content rendering

---@param lines string[]
---@param spans AtlasThreadSpan[]
---@param line_map table<integer, AtlasThreadLineMap>
---@param item AtlasThreadItem
---@param depth integer
---@param pfx AtlasThreadPrefixes
---@param opts AtlasThreadRenderOpts
---@param width integer
local function render_content(lines, spans, line_map, item, depth, pfx, opts, width)
	if item.content == nil then
		return
	end

	local body_prefix = pfx.body_prefix
	local prefix_width = vim.api.nvim_strwidth(body_prefix)
	local content_width = math.max(10, width - prefix_width - opts.padding_x)

	local content = item.markdown
			and markdown.parse(item.content, {
				width = content_width,
				language = item.language,
				file_path = item.file_path,
				language_aliases = item.language_aliases,
			})
		or { lines = utils.sanitize_lines(item.content) }

	local max = opts.content_max_lines
	if type(max) == "function" then
		max = max(item)
	end
	local truncated = type(max) == "number" and max > 0 and #content.lines > max
	if truncated then
		content.lines = vim.list_slice(content.lines, 1, max)
	end

	local rendered_content = wrap_content(content, content_width, body_prefix)
	local content_start = #lines + 1
	utils.append_block(lines, spans, rendered_content)
	for row_index, row in ipairs(rendered_content.lines) do
		local line = content_start + row_index - 1
		line_map[line] = make_line_map(item, "content", depth)

		local segments = opts.content_hl(item, row:sub(#body_prefix + 1), row_index)
		if segments then
			for _, seg in ipairs(segments) do
				span(spans, line - 1, #body_prefix + seg.start_col, #body_prefix + seg.end_col, seg.hl_group)
			end
		end
	end

	-- Indicator when content was truncated.
	if truncated then
		local key = opts.content_truncated_key
		local prefix = key and "Press " or ""
		local suffix = key and " to expand" or ""
		local hint_text = key and (prefix .. key .. suffix) or ".."
		local hint_padding = key and math.max(0, math.floor((content_width - vim.api.nvim_strwidth(hint_text)) / 2))
			or 0
		local hint_start = #body_prefix + hint_padding
		local full_line = body_prefix .. string.rep(" ", hint_padding) .. hint_text
		lines[#lines + 1] = full_line
		line_map[#lines] = make_line_map(item, "content_truncated", depth)
		if #body_prefix > 0 then
			span(spans, #lines - 1, 0, #body_prefix, "AtlasTextMuted")
		end
		if key then
			local key_start = hint_start + #prefix
			span(spans, #lines - 1, hint_start, key_start, "AtlasTextMuted")
			span(spans, #lines - 1, key_start, key_start + #key, "Normal")
			span(spans, #lines - 1, key_start + #key, #full_line, "AtlasTextMuted")
		else
			span(spans, #lines - 1, hint_start, #full_line, "AtlasTextMuted")
		end
	end
end

-- Footer rendering

---@param lines string[]
---@param spans AtlasThreadSpan[]
---@param line_map table<integer, AtlasThreadLineMap>
---@param item AtlasThreadItem
---@param depth integer
---@param pfx AtlasThreadPrefixes
---@param has_children boolean
---@param show_connectors boolean
local function render_footer(lines, spans, line_map, item, depth, pfx, has_children, show_connectors)
	local footer_items = item.footer_items or {}
	if #footer_items == 0 then
		return
	end

	local footer_prefix = pfx.body_prefix
	if depth == 0 and has_children and show_connectors then
		footer_prefix = pfx.pad .. "│ "
	end

	local footer_text = ""
	local footer_spans = {}
	for index, footer_item in ipairs(footer_items) do
		if index > 1 then
			footer_text = footer_text .. "   "
		end
		local start_col = #footer_text
		footer_text = footer_text .. footer_item.text
		if footer_item.highlights and #footer_item.highlights > 0 then
			for _, highlight in ipairs(footer_item.highlights) do
				table.insert(footer_spans, {
					start_col = start_col + highlight.start_col,
					end_col = start_col + highlight.end_col,
					hl_group = highlight.hl_group,
				})
			end
		else
			table.insert(footer_spans, {
				start_col = start_col,
				end_col = #footer_text,
				hl_group = footer_item.hl_group or "AtlasTextMuted",
			})
		end
	end
	local full_line = footer_prefix .. footer_text
	lines[#lines + 1] = full_line
	line_map[#lines] = make_line_map(item, "footer", depth)
	if #footer_prefix > 0 then
		span(spans, #lines - 1, 0, #footer_prefix, "AtlasTextMuted")
	end
	for _, highlight in ipairs(footer_spans) do
		span(
			spans,
			#lines - 1,
			#footer_prefix + highlight.start_col,
			#footer_prefix + highlight.end_col,
			highlight.hl_group
		)
	end
end

-- Blank / separator lines

---@param lines string[]
---@param spans AtlasThreadSpan[]
---@param prefix string
local function blank_line(lines, spans, prefix)
	lines[#lines + 1] = prefix
	if #prefix > 0 then
		span(spans, #lines - 1, 0, #prefix, "AtlasTextMuted")
	end
end

---@param width integer
---@param padding_x integer
---@param sep_char string
---@return string
local function separator_line(width, padding_x, sep_char)
	local content_width = math.max(8, width - (padding_x * 2))
	return string.rep(" ", padding_x) .. string.rep(sep_char, content_width)
end

---@param lines string[]
---@param spans AtlasThreadSpan[]
---@param line_map table<integer, AtlasThreadLineMap>
---@param item AtlasThreadItem
---@param depth integer
---@param branch_prefix string
---@param is_last boolean
---@param opts AtlasThreadRenderOpts
---@param width integer
local function render_item(lines, spans, line_map, item, depth, branch_prefix, is_last, opts, width)
	local linked = opts.mode == "linked"
	local show_connectors = opts.show_connectors
	local pfx = compute_prefixes(depth, branch_prefix, is_last, opts.padding_x, show_connectors)

	if depth == 0 then
		if linked then
			pfx.body_prefix = pfx.pad .. (show_connectors and not is_last and "│ " or "  ")
		end
		if opts.content_prefix then
			pfx.body_prefix = pfx.pad .. opts.content_prefix
		end
	end

	render_header(lines, spans, line_map, item, depth, pfx, opts, width)
	render_content(lines, spans, line_map, item, depth, pfx, opts, width)

	local children = item.children or {}
	render_footer(lines, spans, line_map, item, depth, pfx, #children > 0, show_connectors)

	for index, child in ipairs(children) do
		local gap
		if not show_connectors then
			gap = pfx.pad .. branch_prefix .. (depth == 0 and " " or pfx.continuation)
		elseif depth == 0 then
			gap = pfx.pad .. "│"
		else
			gap = pfx.pad .. branch_prefix .. pfx.continuation
		end
		blank_line(lines, spans, gap)

		local child_branch = branch_prefix .. pfx.continuation
		-- Linked replies continue to the next root item.
		local child_is_last = index == #children and (not linked or depth > 0)
		render_item(lines, spans, line_map, child, depth + 1, child_branch, child_is_last, opts, width)
	end

	if linked and depth == 0 and #children > 0 then
		blank_line(lines, spans, pfx.pad .. (show_connectors and "│" or " "))
	end
end

---Render threads into lines, highlights and a line map.
---@param items AtlasThreadItem[]|nil Root-level items to render
---@param width integer Available buffer width (for right_text alignment and separators)
---@param opts AtlasThreadRenderOpts|nil
---@return string[] lines, AtlasThreadSpan[] spans, table<integer, AtlasThreadLineMap> line_map
function M.render(items, width, opts)
	---@type AtlasThreadRenderOpts
	opts = vim.tbl_extend("force", {
		padding_x = 2,
		mode = "tree",
		show_connectors = true,
		separator = "─",
		author_hl = default_author_hl,
		additional_hl = noop_hl,
		content_hl = noop_hl,
	}, opts or {})

	local lines = {} ---@type string[]
	local spans = {} ---@type AtlasThreadSpan[]
	local line_map = {} ---@type table<integer, AtlasThreadLineMap>
	local list = items or {}

	local is_linked = opts.mode == "linked"
	local padding_x = opts.padding_x
	local pad = string.rep(" ", padding_x)

	for idx, item in ipairs(list) do
		local is_last_root = idx == #list

		render_item(lines, spans, line_map, item, 0, "", is_last_root, opts, width)

		if idx < #list then
			if is_linked then
				blank_line(lines, spans, pad .. (opts.show_connectors and "│" or " "))
			else
				local sep = separator_line(width, padding_x, opts.separator)
				lines[#lines + 1] = sep
				span(spans, #lines - 1, 0, #sep, "AtlasTextMuted")
			end
		end
	end

	return lines, spans, line_map
end

return M
