--- Thanks to claude code. Seems to work for now..
local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

---@alias AtlasThreadV2Mode "tree" | "linked"

---@class AtlasThreadV2Item
---@field icon string|nil                  Icon string rendered before author
---@field icon_hl string|nil               Highlight group for the icon
---@field author string|nil                Display name of the author
---@field additional string|nil            Extra text between author and timestamp
---@field right_text string|nil             Right-aligned text (e.g. timestamp, hash)
---@field content string|nil               Body text (may contain newlines)
---@field footer_items string[]|nil        Action labels shown in the footer row
---@field children AtlasThreadV2Item[]|nil Nested replies
---@field meta table|nil                   Arbitrary metadata passed through
---@field line_map table|nil               Extra fields merged into every line-map entry

---@class AtlasThreadV2RenderOpts
---@field padding_x integer|nil                                                                Horizontal padding (default 2)
---@field mode AtlasThreadV2Mode|nil                                                           Rendering mode (default "tree")
---@field separator string|nil                                                                 Character for root separators (default "─")
---@field content_max_lines integer|nil                                                        Max visible content lines per item (nil = unlimited). Truncated with "…"
---@field author_hl fun(item: AtlasThreadV2Item, author: string): string|nil                   Returns hl group for author
---@field additional_hl fun(item: AtlasThreadV2Item, additional: string): string|nil            Returns hl group for additional text
---@field content_hl fun(item: AtlasThreadV2Item, row: string, row_index: integer): table[]|nil Returns segments for content
---@field icon_hl_fn fun(item: AtlasThreadV2Item): string|nil                                  Override icon highlight

---@class AtlasThreadV2Span
---@field line integer    0-indexed line number
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@class AtlasThreadV2LineMap
---@field kind string
---@field item AtlasThreadV2Item
---@field [string] any

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

---@param item AtlasThreadV2Item
---@param part string
---@param depth integer
---@return AtlasThreadV2LineMap
local function make_line_map(item, part, depth)
	local kind = part
	if depth > 0 then
		kind = "thread_" .. part
	end

	---@type AtlasThreadV2LineMap
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

---@param spans AtlasThreadV2Span[]
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

---@param line_map table<integer, AtlasThreadV2LineMap>
---@param idx integer
---@param map AtlasThreadV2LineMap
local function map_line(line_map, idx, map)
	line_map[idx] = map
end

---@param author string
---@return string
local function default_author_hl(_, author)
	if type(author) ~= "string" or author == "" then
		return "AtlasTextMutedItalic"
	end

	local normalized = vim.trim(author):lower()
	if normalized == "" or normalized == "unknown" or normalized == "none" or normalized == "unassigned" then
		return "AtlasTextMutedItalic"
	end

	return highlights.dynamic_for(normalized) or "AtlasTextMuted"
end

---@return nil
local function noop_hl()
	return nil
end

-------------------------------------------------------------------------------
-- Prefix computation
-------------------------------------------------------------------------------

---@class ThreadV2Prefixes
---@field pad string            Left padding
---@field connector string      ├─ or └─ or ""
---@field continuation string   │  or "   " or ""
---@field meta_prefix string    Full prefix for the header line
---@field body_prefix string    Full prefix for content/footer lines

---@param depth integer
---@param branch_prefix string
---@param is_last boolean
---@param padding_x integer
---@return ThreadV2Prefixes
local function compute_prefixes(depth, branch_prefix, is_last, padding_x)
	local pad = string.rep(" ", padding_x)
	local connector = ""
	local continuation = ""

	if depth > 0 then
		connector = is_last and "└─ " or "├─ "
		continuation = is_last and "   " or "│  "
	end

	local meta_prefix = pad .. branch_prefix .. connector
	local body_prefix = depth == 0 and pad or (pad .. branch_prefix .. continuation)

	return {
		pad = pad,
		connector = connector,
		continuation = continuation,
		meta_prefix = meta_prefix,
		body_prefix = body_prefix,
	}
end

-------------------------------------------------------------------------------
-- Header rendering
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
---@param line_map table<integer, AtlasThreadV2LineMap>
---@param item AtlasThreadV2Item
---@param depth integer
---@param pfx ThreadV2Prefixes
---@param opts AtlasThreadV2RenderOpts
---@param width integer
local function render_header(lines, spans, line_map, item, depth, pfx, opts, width)
	local parts = {}
	local col_markers = {} -- { {start, end, hl} }

	-- Track cursor position relative to start of content (after meta_prefix)
	local cursor = #pfx.meta_prefix

	-- Icon
	local icon = item.icon or ""
	if icon ~= "" then
		local icon_start = cursor
		parts[#parts + 1] = icon .. " "
		cursor = cursor + #icon + 1
		local hl = item.icon_hl
		if type(opts.icon_hl_fn) == "function" then
			hl = opts.icon_hl_fn(item) or hl
		end
		if hl then
			col_markers[#col_markers + 1] = { icon_start, icon_start + #icon, hl }
		end
	end

	-- Author
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
		local padding_x = tonumber(opts.padding_x) or 2
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
		if type(add_hl) == "string" and add_hl ~= "" then
			col_markers[#col_markers + 1] = { add_start, cursor, add_hl }
		end
	end

	if right_text ~= "" then
		-- Snap right_text to the right edge of the row.
		-- Use display width (not byte length) because tree connectors like
		-- ├─ / └─ / │ are multi-byte UTF-8 but only 1-2 columns wide.
		local content_so_far = pfx.meta_prefix .. table.concat(parts, "")
		local display_so_far = vim.api.nvim_strwidth(content_so_far)
		local display_rt = vim.api.nvim_strwidth(right_text)
		local right_edge = width - (tonumber(opts.padding_x) or 2)
		local needed = math.max(2, right_edge - display_so_far - display_rt)
		parts[#parts + 1] = string.rep(" ", needed) .. right_text
		local rt_byte_start = #content_so_far + needed
		col_markers[#col_markers + 1] = { rt_byte_start, rt_byte_start + #right_text, "AtlasTextMuted" }
	end

	local full_line = pfx.meta_prefix .. table.concat(parts, "")
	lines[#lines + 1] = full_line
	map_line(line_map, #lines, make_line_map(item, "header", depth))

	-- Prefix highlight (tree connectors)
	if #pfx.meta_prefix > 0 then
		span(spans, #lines - 1, 0, #pfx.meta_prefix, "AtlasTextMuted")
	end

	-- Apply collected highlights
	for _, m in ipairs(col_markers) do
		span(spans, #lines - 1, m[1], m[2], m[3])
	end
end

-------------------------------------------------------------------------------
-- Content rendering
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
---@param line_map table<integer, AtlasThreadV2LineMap>
---@param item AtlasThreadV2Item
---@param depth integer
---@param pfx ThreadV2Prefixes
---@param opts AtlasThreadV2RenderOpts
local function render_content(lines, spans, line_map, item, depth, pfx, opts, width)
	if item.content == nil then
		return
	end

	local content = tostring(item.content)
	local content_lines = utils.sanitize_lines(content)
	local max = opts.content_max_lines
	local truncated = type(max) == "number" and max > 0 and #content_lines > max

	local visible_count = truncated and max or #content_lines

	-- Available width for content text (after prefix)
	local prefix_dw = vim.api.nvim_strwidth(pfx.body_prefix)
	local padding_x = tonumber(opts.padding_x) or 2
	local content_max_dw = width - prefix_dw - padding_x
	if content_max_dw < 10 then
		content_max_dw = 10
	end

	local row_index = 0
	for src_index = 1, visible_count do
		local row = content_lines[src_index]
		-- Soft-wrap long lines to fit within the available width
		local wrapped = utils.wrap_line(row, content_max_dw)
		for _, wrap_row in ipairs(wrapped) do
			row_index = row_index + 1
			local full_line = pfx.body_prefix .. wrap_row
			lines[#lines + 1] = full_line
			map_line(line_map, #lines, make_line_map(item, "content", depth))

			if #pfx.body_prefix > 0 then
				span(spans, #lines - 1, 0, #pfx.body_prefix, "AtlasTextMuted")
			end

			local segments = opts.content_hl(item, wrap_row, row_index)
			if segments then
				for _, seg in ipairs(segments) do
					span(
						spans,
						#lines - 1,
						#pfx.body_prefix + seg.start_col,
						#pfx.body_prefix + seg.end_col,
						seg.hl_group
					)
				end
			end
		end
	end

	-- Ellipsis indicator when content was truncated
	if truncated then
		local ellipsis = "…"
		local full_line = pfx.body_prefix .. ellipsis
		lines[#lines + 1] = full_line
		map_line(line_map, #lines, make_line_map(item, "content_truncated", depth))

		if #pfx.body_prefix > 0 then
			span(spans, #lines - 1, 0, #pfx.body_prefix, "AtlasTextMuted")
		end
		span(spans, #lines - 1, #pfx.body_prefix, #full_line, "AtlasTextMuted")
	end
end

-------------------------------------------------------------------------------
-- Footer rendering
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
---@param line_map table<integer, AtlasThreadV2LineMap>
---@param item AtlasThreadV2Item
---@param depth integer
---@param pfx ThreadV2Prefixes
---@param has_children boolean
local function render_footer(lines, spans, line_map, item, depth, pfx, has_children)
	local footer_items = item.footer_items or {}
	if #footer_items == 0 then
		return
	end

	local footer_prefix = pfx.body_prefix
	if depth == 0 and has_children then
		footer_prefix = pfx.pad .. "│ "
	end

	local full_line = footer_prefix .. table.concat(footer_items, "   ")
	lines[#lines + 1] = full_line
	map_line(line_map, #lines, make_line_map(item, "footer", depth))
	span(spans, #lines - 1, 0, #full_line, "AtlasTextMuted")
end

-------------------------------------------------------------------------------
-- Blank / separator lines
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
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

-------------------------------------------------------------------------------
-- Recursive item renderer — TREE mode
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
---@param line_map table<integer, AtlasThreadV2LineMap>
---@param item AtlasThreadV2Item
---@param depth integer
---@param branch_prefix string
---@param is_last boolean
---@param opts AtlasThreadV2RenderOpts
---@param width integer
local function render_tree(lines, spans, line_map, item, depth, branch_prefix, is_last, opts, width)
	local padding_x = tonumber(opts.padding_x) or 2
	local pfx = compute_prefixes(depth, branch_prefix, is_last, padding_x)

	render_header(lines, spans, line_map, item, depth, pfx, opts, width)
	render_content(lines, spans, line_map, item, depth, pfx, opts, width)

	local children = item.children or {}
	render_footer(lines, spans, line_map, item, depth, pfx, #children > 0)

	for i, child in ipairs(children) do
		-- Blank connector line before each child
		local sep_prefix
		if depth == 0 then
			sep_prefix = pfx.pad .. "│"
		else
			sep_prefix = pfx.pad .. branch_prefix .. pfx.continuation
		end
		blank_line(lines, spans, sep_prefix)

		local child_branch = branch_prefix .. pfx.continuation
		render_tree(lines, spans, line_map, child, depth + 1, child_branch, i == #children, opts, width)
	end
end

-------------------------------------------------------------------------------
-- Recursive item renderer — LINKED mode
--
-- In linked mode, children are rendered under the parent with │ connectors,
-- but the last child's continuation line leads into a blank gap before the
-- next root item starts fresh.
-------------------------------------------------------------------------------

---@param lines string[]
---@param spans AtlasThreadV2Span[]
---@param line_map table<integer, AtlasThreadV2LineMap>
---@param item AtlasThreadV2Item
---@param depth integer
---@param branch_prefix string
---@param is_last boolean
---@param is_last_root boolean          Whether this is the last root-level item
---@param opts AtlasThreadV2RenderOpts
---@param width integer
local function render_linked(lines, spans, line_map, item, depth, branch_prefix, is_last, is_last_root, opts, width)
	local padding_x = tonumber(opts.padding_x) or 2
	local pfx = compute_prefixes(depth, branch_prefix, is_last, padding_x)

	-- In linked mode, root items get an indented body prefix so content
	-- aligns beneath the header.  Non-last items show │, the last item
	-- uses matching whitespace so the column stays consistent.
	if depth == 0 then
		if is_last_root then
			pfx.body_prefix = pfx.pad .. "  "
		else
			pfx.body_prefix = pfx.pad .. "│ "
		end
	end

	render_header(lines, spans, line_map, item, depth, pfx, opts, width)
	render_content(lines, spans, line_map, item, depth, pfx, opts, width)

	local children = item.children or {}
	render_footer(lines, spans, line_map, item, depth, pfx, #children > 0)

	for i, child in ipairs(children) do
		-- Blank connector line
		local sep_prefix
		if depth == 0 then
			sep_prefix = pfx.pad .. "│"
		else
			sep_prefix = pfx.pad .. branch_prefix .. pfx.continuation
		end
		blank_line(lines, spans, sep_prefix)

		local child_branch = branch_prefix .. pfx.continuation
		-- In linked mode children never mark as "last" so the │ continues
		-- EXCEPT for the truly last child at depth > 0
		local child_is_last = (depth > 0) and (i == #children)
		render_linked(lines, spans, line_map, child, depth + 1, child_branch, child_is_last, is_last_root, opts, width)
	end

	-- In linked mode, after all children of a root item, add a blank │ line
	-- so the next root item visually connects
	if depth == 0 and #children > 0 then
		blank_line(lines, spans, pfx.pad .. "│")
	end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

---Render a list of threaded items into lines, highlight spans, and a line map.
---
---@param items AtlasThreadV2Item[]|nil  Root-level items to render
---@param width integer                  Available buffer width (for right_text alignment and separators)
---@param opts AtlasThreadV2RenderOpts|nil
---@return string[] lines, AtlasThreadV2Span[] spans, table<integer, AtlasThreadV2LineMap> line_map
function M.render(items, width, opts)
	---@type AtlasThreadV2RenderOpts
	local o = vim.tbl_extend("force", {
		padding_x = 2,
		mode = "tree",
		separator = "─",
		content_max_lines = nil,
		author_hl = default_author_hl,
		additional_hl = noop_hl,
		content_hl = noop_hl,
		icon_hl_fn = nil,
	}, opts or {})

	local lines = {} ---@type string[]
	local spans = {} ---@type AtlasThreadV2Span[]
	local line_map = {} ---@type table<integer, AtlasThreadV2LineMap>
	local list = items or {}

	if #list == 0 then
		return lines, spans, line_map
	end

	local is_linked = o.mode == "linked"
	local padding_x = tonumber(o.padding_x) or 2
	local pad = string.rep(" ", padding_x)

	for idx, item in ipairs(list) do
		local is_last_root = idx == #list

		if is_linked then
			render_linked(lines, spans, line_map, item, 0, "", is_last_root, is_last_root, o, width)
		else
			render_tree(lines, spans, line_map, item, 0, "", is_last_root, o, width)
		end

		if idx < #list then
			if is_linked then
				-- Linked mode: │ continuation line between root items
				blank_line(lines, spans, pad .. "│")
			else
				local sep = separator_line(width, padding_x, o.separator)
				lines[#lines + 1] = sep
				span(spans, #lines - 1, 0, #sep, "AtlasTextMuted")
			end
		end
	end

	return lines, spans, line_map
end

return M
