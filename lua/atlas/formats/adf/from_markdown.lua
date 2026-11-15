local M = {}

local function text_node(text, marks)
	return {
		type = "text",
		text = text,
		marks = marks,
	}
end

local function append_text(nodes, text, marks)
	if text == nil or text == "" then
		return
	end

	local last = nodes[#nodes]
	if marks == nil and last ~= nil and last.type == "text" and last.marks == nil then
		last.text = (last.text or "") .. text
		return
	end

	table.insert(nodes, text_node(text, marks))
end

local status_emoji_to_color = {
	[""] = "blue",
	[""] = "green",
	[""] = "yellow",
	[""] = "red",
	[""] = "neutral",
}

---@param text string
---@param i integer
---@return string, integer
local function utf8_char_at(text, i)
	local b1 = text:byte(i)
	if b1 == nil then
		return "", 1
	end

	if b1 < 0x80 then
		return text:sub(i, i), 1
	end

	if b1 >= 0xC2 and b1 <= 0xDF then
		return text:sub(i, i + 1), 2
	end

	if b1 >= 0xE0 and b1 <= 0xEF then
		return text:sub(i, i + 2), 3
	end

	if b1 >= 0xF0 and b1 <= 0xF4 then
		return text:sub(i, i + 3), 4
	end

	return text:sub(i, i), 1
end

local inline_marks = {
	["**"] = "strong",
	["~~"] = "strike",
	["*"] = "em",
	["`"] = "code",
}

local function parse_inline(text)
	local nodes = {}
	local i = 1

	local status_icon, icon_size = utf8_char_at(text, 1)
	local status_color = status_emoji_to_color[status_icon]
	if status_color ~= nil then
		local rest = text:sub(icon_size + 1)
		local leading_ws, status_text, trailing_ws = rest:match("^(%s+)([^%s].-)(%s*)$")
		if leading_ws ~= nil and status_text ~= nil then
			table.insert(nodes, {
				type = "status",
				attrs = {
					text = status_text,
					color = status_color,
					style = "",
				},
			})
			if trailing_ws ~= nil and trailing_ws ~= "" then
				append_text(nodes, trailing_ws)
			end
			return nodes
		end
	end

	while i <= #text do
		local icon, size = utf8_char_at(text, i)
		local emoji_start, emoji_end, emoji_code
		local mention_start, mention_end, mention_label, mention_id
		local link_start, link_end, label, url
		if icon == ":" then
			emoji_start, emoji_end, emoji_code = text:find(":([%w_+-]+):", i)
		elseif icon == "[" then
			mention_start, mention_end, mention_label, mention_id = text:find("%[(.-)%]%{mention:([^}]+)%}", i)
			link_start, link_end, label, url = text:find("%[(.-)%]%((.-)%)", i)
		end

		local delimiter = text:sub(i, i + 1)
		local mark = inline_marks[delimiter]
		if mark == nil then
			delimiter = icon
			mark = inline_marks[delimiter]
		end
		local close = mark and text:find(delimiter, i + #delimiter, true)

		if emoji_start == i then
			local short_name = ":" .. emoji_code .. ":"
			table.insert(nodes, {
				type = "emoji",
				attrs = {
					shortName = short_name,
					text = short_name,
				},
			})
			i = emoji_end + 1
		elseif mention_start == i then
			local mention_text = mention_label
			if mention_text ~= "" and mention_text:sub(1, 1) ~= "@" then
				mention_text = "@" .. mention_text
			end
			table.insert(nodes, {
				type = "mention",
				attrs = {
					id = mention_id,
					text = mention_text,
					accessLevel = "",
				},
			})
			i = mention_end + 1
		elseif link_start == i then
			local date_timestamp = url:match("^atlas%-date:(.+)$")
			local parsed_mention_id = url:match("^atlas%-mention:(.+)$")
			local parsed_emoji_short_name = url:match("^atlas%-emoji:(.+)$")

			if date_timestamp ~= nil and date_timestamp ~= "" then
				table.insert(nodes, {
					type = "date",
					attrs = {
						timestamp = date_timestamp,
					},
				})
			elseif parsed_mention_id ~= nil and parsed_mention_id ~= "" then
				local mention_text = label
				if mention_text ~= "" and mention_text:sub(1, 1) ~= "@" then
					mention_text = "@" .. mention_text
				end
				table.insert(nodes, {
					type = "mention",
					attrs = {
						id = parsed_mention_id,
						text = mention_text,
						accessLevel = "",
					},
				})
			elseif parsed_emoji_short_name ~= nil and parsed_emoji_short_name ~= "" then
				table.insert(nodes, {
					type = "emoji",
					attrs = {
						shortName = parsed_emoji_short_name,
						text = parsed_emoji_short_name,
					},
				})
			else
				table.insert(nodes, {
					type = "text",
					text = label,
					marks = {
						{ type = "link", attrs = { href = url } },
					},
				})
			end
			i = link_end + 1
		elseif close then
			append_text(nodes, text:sub(i + #delimiter, close - 1), { { type = mark } })
			i = close + #delimiter
		else
			append_text(nodes, icon)
			i = i + size
		end
	end

	return nodes
end

---@param line string
---@return string[]
local function parse_table_cells(line)
	local row = vim.trim(line)
	if row:sub(1, 1) == "|" then
		row = row:sub(2)
	end
	if row:sub(-1) == "|" then
		row = row:sub(1, -2)
	end

	local cells = vim.split(row, "|", { plain = true })
	for i, cell in ipairs(cells) do
		cells[i] = vim.trim(cell)
	end
	return cells
end

---@param line string
---@return boolean
local function is_table_row(line)
	local row = vim.trim(line)
	if row == "" then
		return false
	end
	return row:find("|", 1, true) ~= nil
end

---@param line string
---@return boolean
local function is_table_separator(line)
	local cells = parse_table_cells(line)
	if #cells == 0 then
		return false
	end

	for _, cell in ipairs(cells) do
		if not cell:match("^:?-+:?$") then
			return false
		end
	end

	return true
end

local line_handlers = {}

-- ```lang
-- code here
-- ```
line_handlers.codeBlock = {
	match = function(line)
		return line:match("^```") ~= nil
	end,
	parse = function(line, ctx)
		local lang = line:match("^```(.*)")
		local code_lines = {}
		ctx.i = ctx.i + 1

		while ctx.i <= #ctx.lines and not ctx.lines[ctx.i]:match("^```") do
			table.insert(code_lines, ctx.lines[ctx.i])
			ctx.i = ctx.i + 1
		end

		local node = {
			type = "codeBlock",
			content = {
				{ type = "text", text = table.concat(code_lines, "\n") },
			},
		}
		if lang ~= nil and lang ~= "" then
			node.attrs = { language = lang }
		end

		return node
	end,
}

-- ## Heading text
line_handlers.heading = {
	match = function(line)
		return line:match("^#+%s") ~= nil
	end,
	parse = function(line)
		local hashes, content = line:match("^(#+)%s+(.*)")
		return {
			type = "heading",
			attrs = { level = #hashes },
			content = parse_inline(content),
		}
	end,
}

-- > [!NOTE]
-- > panel content
line_handlers.panel = {
	match = function(line, ctx)
		if not line:match("^>%s?%[!%u+%]%s*$") then
			return false
		end
		return ctx.i + 1 <= #ctx.lines and ctx.lines[ctx.i + 1]:match("^>%s?") ~= nil
	end,
	parse = function(line, ctx)
		local callout = line:match("^>%s?%[!(%u+)%]")
		local reverse_map = {
			NOTE = "info",
			WARNING = "warning",
			CAUTION = "error",
			TIP = "success",
		}
		local panel_type = reverse_map[callout] or "info"

		ctx.i = ctx.i + 1
		local content_lines = {}
		while ctx.i <= #ctx.lines and ctx.lines[ctx.i]:match("^>%s?") do
			table.insert(content_lines, (ctx.lines[ctx.i]:gsub("^>%s?", "")))
			ctx.i = ctx.i + 1
		end
		ctx.i = ctx.i - 1

		return {
			type = "panel",
			attrs = { panelType = panel_type },
			content = {
				{
					type = "paragraph",
					content = parse_inline(table.concat(content_lines, "\n")),
				},
			},
		}
	end,
}

-- > quoted text
line_handlers.blockquote = {
	match = function(line)
		return line:match("^>%s?") ~= nil
	end,
	parse = function(_, ctx)
		local content_lines = {}
		while ctx.i <= #ctx.lines and ctx.lines[ctx.i]:match("^>%s?") do
			table.insert(content_lines, (ctx.lines[ctx.i]:gsub("^>%s?", "")))
			ctx.i = ctx.i + 1
		end
		ctx.i = ctx.i - 1

		return {
			type = "blockquote",
			content = {
				{
					type = "paragraph",
					content = parse_inline(table.concat(content_lines, "\n")),
				},
			},
		}
	end,
}

---@param line string
---@return "bulletList"|"orderedList"|"taskList"|nil, integer, string, string|nil
local function list_line(line)
	local indent, checkbox, text = line:match("^(%s*)[-*+]%s+%[([ xX])%]%s+(.*)$")
	if indent then
		return "taskList", #indent, text, checkbox == " " and "TODO" or "DONE"
	end

	indent, text = line:match("^(%s*)[-*+]%s+(.*)$")
	if indent then
		return "bulletList", #indent, text
	end

	indent, text = line:match("^(%s*)%d+%.%s+(.*)$")
	if indent then
		return "orderedList", #indent, text
	end

	return nil, 0, ""
end

---@param ctx { lines: string[], i: integer }
---@return table
local function parse_list(ctx)
	local list_type, indent = list_line(ctx.lines[ctx.i])
	local list = { type = list_type, content = {} }
	if list_type == "taskList" then
		list.attrs = { localId = "" }
	end

	while ctx.i <= #ctx.lines do
		local item_type, item_indent, text, state = list_line(ctx.lines[ctx.i])
		if item_type == nil or item_indent < indent then
			break
		end

		if item_indent > indent then
			local nested = parse_list(ctx)
			if list_type == "taskList" then
				table.insert(list.content, nested)
			else
				table.insert(list.content[#list.content].content, nested)
			end
		elseif item_type ~= list_type then
			break
		elseif list_type == "taskList" then
			table.insert(list.content, {
				type = "taskItem",
				attrs = { localId = "", state = state },
				content = parse_inline(text),
			})
			ctx.i = ctx.i + 1
		else
			table.insert(list.content, {
				type = "listItem",
				content = { { type = "paragraph", content = parse_inline(text) } },
			})
			ctx.i = ctx.i + 1
		end
	end

	return list
end

-- * bullet item
-- 1. ordered item
-- - [x] task item
--   * nested item
line_handlers.list = {
	match = function(line)
		return list_line(line) ~= nil
	end,
	parse = function(_, ctx)
		local list = parse_list(ctx)
		ctx.i = ctx.i - 1
		return list
	end,
}

-- ---
line_handlers.rule = {
	match = function(line)
		return line == "---"
	end,
	parse = function()
		return { type = "rule" }
	end,
}

-- | col1 | col2 |
-- | --- | --- |
-- | val1 | val2 |
line_handlers.table = {
	match = function(line, ctx)
		return ctx.i + 1 <= #ctx.lines and is_table_row(line) and is_table_separator(ctx.lines[ctx.i + 1])
	end,
	parse = function(line, ctx)
		local headers = parse_table_cells(line)
		local table_node = {
			type = "table",
			content = {},
		}

		local header_row = {
			type = "tableRow",
			content = {},
		}
		for _, cell in ipairs(headers) do
			table.insert(header_row.content, {
				type = "tableHeader",
				content = {
					{
						type = "paragraph",
						content = parse_inline(cell),
					},
				},
			})
		end
		table.insert(table_node.content, header_row)

		ctx.i = ctx.i + 2
		while ctx.i <= #ctx.lines and is_table_row(ctx.lines[ctx.i]) do
			local cells = parse_table_cells(ctx.lines[ctx.i])
			local body_row = {
				type = "tableRow",
				content = {},
			}
			for _, cell in ipairs(cells) do
				table.insert(body_row.content, {
					type = "tableCell",
					content = {
						{
							type = "paragraph",
							content = parse_inline(cell),
						},
					},
				})
			end
			table.insert(table_node.content, body_row)
			ctx.i = ctx.i + 1
		end

		ctx.i = ctx.i - 1
		return table_node
	end,
}

-- plain paragraph text
line_handlers.paragraph = {
	match = function(line)
		return line ~= ""
	end,
	parse = function(line)
		return {
			type = "paragraph",
			content = parse_inline(line),
		}
	end,
}

-- Order matters: checked top to bottom, paragraph must be last
local handler_order = {
	"codeBlock",
	"heading",
	"panel",
	"blockquote",
	"list",
	"rule",
	"table",
	"paragraph",
}

---@param text string
---@return table
function M.to_adf(text)
	local lines = vim.split(text or "", "\n", { plain = true })
	local doc = {
		type = "doc",
		version = 1,
		content = {},
	}

	local ctx = { lines = lines, i = 1 }

	while ctx.i <= #lines do
		local line = lines[ctx.i]

		if line == "" then
			ctx.i = ctx.i + 1
		else
			for _, name in ipairs(handler_order) do
				local handler = line_handlers[name]
				if handler.match(line, ctx) then
					table.insert(doc.content, handler.parse(line, ctx))
					break
				end
			end
			ctx.i = ctx.i + 1
		end
	end

	return doc
end

return M
