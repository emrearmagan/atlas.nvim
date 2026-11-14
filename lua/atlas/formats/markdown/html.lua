local M = { inline = {}, block = {} }

local function elements()
	return require("atlas.formats.markdown.elements")
end

local tag_names = [[
	a abbr b bdi bdo big blockquote br caption center cite code col colgroup dd del details dfn div dl dt em
	figcaption figure font h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p picture pre q rp rt ruby s samp small
	source span strike strong sub summary sup table tbody td tfoot th thead tr tt u ul var wbr
]]

local known_tags = {}
for name in tag_names:gmatch("%S+") do
	known_tags[name] = true
end

local block_tags = { details = true, div = true, p = true, summary = true, table = true }

local tag_styles = {
	b = "strong",
	strong = "strong",
	i = "em",
	em = "em",
	code = "inline_code",
	kbd = "inline_code",
	tt = "inline_code",
	s = "strike",
	del = "strike",
	strike = "strike",
}

local named_entities = {
	nbsp = " ",
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	ndash = "–",
	mdash = "—",
	hellip = "…",
	middot = "·",
	bull = "•",
	times = "×",
	larr = "←",
	rarr = "→",
	copy = "©",
	reg = "®",
	trade = "™",
}

local function utf8_char(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	elseif code < 0x10000 then
		return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
	end
	return string.char(
		0xF0 + math.floor(code / 0x40000),
		0x80 + math.floor(code / 0x1000) % 0x40,
		0x80 + math.floor(code / 0x40) % 0x40,
		0x80 + code % 0x40
	)
end

local function decode_entity(body)
	if named_entities[body] then
		return named_entities[body]
	end

	local code = tonumber(body:match("^#(%d+)$") or "") or tonumber(body:match("^#[xX](%x+)$") or "", 16)
	if not code or code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
		return
	end
	return code == 0xA0 and " " or utf8_char(code)
end

local function decode_entities(text)
	return (text:gsub("&(#?%w+);", function(body)
		return decode_entity(body)
	end))
end

local function attributes(tag)
	local values = {}
	for name, _, value in tag:gmatch("([%w_-]+)%s*=%s*(['\"])(.-)%2") do
		values[name:lower()] = decode_entities(value)
	end
	return values
end

local function match_tag(text)
	local tag, closing, name, rest = text:match("^(<(/?)(%a%w*)([^>]*)>)")
	if not tag or not (rest == "" or rest:match("^[%s/]")) then
		return
	end

	name = name:lower()
	if known_tags[name] then
		return closing, name, tag
	end
end

-- <img src="https://example.com/logo.png" alt="logo" />
-- { text = "󰋩 logo", style = "image", url = "https://example.com/logo.png" }.
-- An empty label displays "image".
function M.inline.image(text)
	local tag = text:match("^<img%s[^>]*>")
	if not tag then
		return
	end

	local values = attributes(tag)
	if not values.src or values.src == "" then
		return
	end

	local label = values.alt
	if not label or label == "" then
		label = "image"
	end
	return { text = "󰋩 " .. label, style = "image", url = values.src }, #tag
end

-- <!-- **draft** -->
-- { text = "<!-- **draft** -->", style = "comment" }.
-- Inline comments must close on the same line.
function M.inline.comment(text)
	if text:sub(1, 4) ~= "<!--" then
		return
	end

	local _, closing_end = text:find("-->", 5, true)
	if closing_end then
		return { text = text:sub(1, closing_end), style = "comment" }, closing_end
	end
end

function M.inline.entity(text)
	local entity, body = text:match("^(&(#?%w+);)")
	local decoded = body and decode_entity(body)
	if decoded then
		return { text = decoded }, #entity
	end
end

function M.inline.tag(text)
	local closing, name, tag = match_tag(text)
	if not name then
		return
	end

	if name == "br" then
		return { text = " " }, #tag
	end

	if closing == "" and (tag_styles[name] or name == "a") then
		local close_start, close_end = text:lower():find("</" .. name .. "%s*>", #tag + 1)
		if close_start then
			local content = elements().join(elements().parse_inline(text:sub(#tag + 1, close_start - 1)))
			local url = name == "a" and attributes(tag).href or nil
			return { text = content, style = tag_styles[name] or (url and "link" or nil), url = url }, close_end
		end
	end

	return { text = "" }, #tag
end

local function split_line(line)
	local prefix = line:match("^%s*>[>%s]*") or ""
	local parts, start, position = {}, #prefix + 1, #prefix + 1

	local function cut(finish)
		local part = line:sub(start, finish - 1)
		if part:find("%S") then
			parts[#parts + 1] = prefix .. part
		end
		start = finish
	end

	while position <= #line do
		local character = line:sub(position, position)
		if line:sub(position, position + 3) == "<!--" then
			local _, comment_end = line:find("-->", position + 4, true)
			position = (comment_end or #line) + 1
		elseif character == "`" then
			local ticks = line:match("^`+", position)
			local _, closing_end = line:find(ticks, position + #ticks, true)
			position = (closing_end or position + #ticks - 1) + 1
		elseif character == "<" then
			local closing, name, tag = match_tag(line:sub(position))
			if name and block_tags[name] then
				cut(position)
				local finish = position + #tag
				if closing == "" and (name == "summary" or name == "table") then
					local _, unit_end = line:lower():find("</" .. name .. "%s*>", finish)
					if not unit_end then
						break
					end
					finish = unit_end + 1
				end
				cut(finish)
				position = finish
			else
				position = position + 1
			end
		else
			position = position + 1
		end
	end
	cut(#line + 1)

	if #parts <= 1 then
		return { line }
	end
	return parts
end

-- GitHub renders block-level HTML wherever it appears, but the block handlers only look at line starts.
---@param lines string[]
---@return string[]
function M.split_blocks(lines)
	local result = {}
	local fence

	for _, line in ipairs(lines) do
		if fence then
			local closing = line:match("^(" .. fence:sub(1, 1) .. "+)%s*$")
			if closing and #closing >= #fence then
				fence = nil
			end
			result[#result + 1] = line
		else
			fence = line:match("^(```+)[^`]*$") or line:match("^(~~~+)")
			if fence or not line:find("<", 1, true) or line:match("^%s*|") then
				result[#result + 1] = line
			else
				vim.list_extend(result, split_line(line))
			end
		end
	end

	return result
end

--   <!--
--   **draft**
--   -->
-- the same lines, muted, with Markdown markers kept literal.
function M.block.comment(lines, index)
	local opening_end = lines[index]:match("^%s*<!%-%-()")
	if not opening_end then
		return
	end

	local rows = {}

	while index <= #lines do
		local line = lines[index]
		rows[#rows + 1] = { { text = line, style = "comment" } }

		if line:find("-->", opening_end, true) then
			return rows, index + 1
		end

		index = index + 1
		opening_end = 1
	end

	return rows, index
end

function M.block.tags(lines, index)
	local rest = lines[index]
	if not rest:match("^%s*<") then
		return
	end

	repeat
		local _, name, tag = match_tag(vim.trim(rest))
		if not name or name == "img" then
			return
		end
		rest = vim.trim(rest):sub(#tag + 1)
	until not rest:find("%S")

	return {}, index + 1
end

function M.block.heading(lines, index)
	local level, title = lines[index]:match("^%s*<[hH]([1-6])[^>]*>(.-)</[hH]%1>%s*$")
	if level then
		local row = elements().parse_inline(title)
		row.hl = "heading_" .. level
		return { row }, index + 1
	end
end

-- <summary><strong>Title</strong></summary>
-- { { { text = "▾ Title" } } }.
function M.block.summary(lines, index)
	local title = lines[index]:match("^%s*<summary>(.-)</summary>%s*$")
	if title then
		return { { { text = "▾ " .. elements().join(elements().parse_inline(title)) } } }, index + 1
	end
end

function M.block.table(lines, index, opts)
	if not lines[index]:match("^%s*<[tT][aA][bB][lL][eE][%s>]") then
		return
	end

	local finish = index
	while not lines[finish]:lower():find("</table%s*>") do
		finish = finish + 1
		if finish > #lines then
			return
		end
	end

	local source = table.concat(lines, " ", index, finish)
	local rows = {}
	local header = false

	for row in source:gsub("<[tT][rR]", "\0"):gmatch("%z([^%z]*)") do
		local cells = {}
		local all_headers = true
		for kind, cell_attributes, content in row:gmatch("<[tT]([hHdD])([^>]*)>(.-)</[tT][hHdD]%s*>") do
			cells[#cells + 1] = vim.trim(content)
			all_headers = all_headers and kind:lower() == "h"
			local span = tonumber(attributes(cell_attributes).colspan or "") or 1
			for _ = 2, math.min(span, 50) do
				cells[#cells + 1] = ""
			end
		end

		if #cells > 0 then
			rows[#rows + 1] = cells
			if #rows == 1 then
				header = all_headers
			end
		end
	end

	if #rows == 0 then
		return
	end

	return require("atlas.formats.markdown.table").render(rows, {}, opts, header), finish + 1
end

return M
