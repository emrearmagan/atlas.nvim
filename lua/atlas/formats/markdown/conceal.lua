local M = {}

-- Deleted ranges are replaced by this marker so lines that contained nothing but
-- hidden HTML can be dropped afterwards instead of rendering as blank rows.
local DELETED = "\1"

local named_entities = {
	nbsp = " ",
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	mdash = "—",
	ndash = "–",
	hellip = "…",
	copy = "©",
}

local function decode_entity(text)
	local body = text:match("^&(.-);$")
	if not body then
		return text
	end

	local hex, decimal = body:match("^#[xX](%x+)$"), body:match("^#(%d+)$")
	local code = hex and tonumber(hex, 16) or decimal and tonumber(decimal)
	if code then
		if code == 160 then
			return " "
		end
		local valid = code > 0 and code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF)
		return valid and vim.fn.nr2char(code) or text
	end

	return named_entities[body] or text
end

-- Whole-line tags in html_block nodes are handled by the block handlers in html.lua.
local block_preserved = { details = true, p = true, a = true }

local function replace_tag(text, in_block)
	if text:sub(1, 4) == "<!--" then
		return DELETED
	end

	local name = text:match("^</?(%a[%w-]*)")
	if not name then
		return text
	end
	name = name:lower()

	if name == "img" or (in_block and block_preserved[name]) then
		return text
	end
	if name == "summary" then
		if in_block then
			return text
		end
		return text:sub(2, 2) == "/" and DELETED or "▾ "
	end
	if name == "br" or (name == "tr" and text:sub(2, 2) == "/") then
		return "\n"
	end
	if (name == "td" or name == "th") and text:sub(2, 2) == "/" then
		return "  "
	end
	return DELETED
end

-- html_block nodes are not inline-parsed, so hide their comments and tags with patterns.
local function replace_block(text)
	local out = {}
	local position = 1
	while position <= #text do
		local comment = text:find("<!--", position, true)
		local tag = text:find("</?%a", position)
		local start = comment and tag and math.min(comment, tag) or comment or tag
		if not start then
			break
		end

		out[#out + 1] = text:sub(position, start - 1)
		if start == comment then
			local _, finish = text:find("-->", start + 4, true)
			out[#out + 1] = DELETED
			position = (finish or #text) + 1
		else
			local finish = text:find(">", start, true)
			if not finish then
				out[#out + 1] = text:sub(start)
				position = #text + 1
			else
				local replaced = replace_tag(text:sub(start, finish), true)
				out[#out + 1] = replaced
				position = finish + 1
			end
		end
	end
	out[#out + 1] = text:sub(position)
	return (table.concat(out):gsub("&#?%w+;", decode_entity))
end

local function collect(node, edits, source)
	local kind = node:type()
	if kind == "entity_reference" or kind == "numeric_character_reference" then
		local _, _, start_byte, _, _, end_byte = node:range(true)
		local text = source:sub(start_byte + 1, end_byte)
		local decoded = decode_entity(text)
		if decoded ~= text then
			edits[#edits + 1] = { start_byte, end_byte, decoded }
		end
		return
	end

	if kind == "html_tag" or kind == "html_block" then
		local _, _, start_byte, _, _, end_byte = node:range(true)
		local text = source:sub(start_byte + 1, end_byte)
		local replacement = kind == "html_tag" and replace_tag(text) or replace_block(text)
		if replacement ~= text then
			edits[#edits + 1] = { start_byte, end_byte, replacement }
		end
		return
	end

	for child in node:iter_children() do
		collect(child, edits, source)
	end
end

---Remove HTML tags and comments from Markdown source using Treesitter.
---Returns the source unchanged when the Markdown parsers are unavailable.
---@param source string
---@return string
function M.strip(source)
	if not source:find("[<&]") then
		return source
	end

	local ok, result = pcall(function()
		local parser = vim.treesitter.get_string_parser(source, "markdown")
		parser:parse(true)

		local edits = {}
		parser:for_each_tree(function(tree)
			collect(tree:root(), edits, source)
		end)
		return edits
	end)
	if not ok then
		return source
	end

	table.sort(result, function(a, b)
		return a[1] > b[1]
	end)

	local limit = #source
	for _, edit in ipairs(result) do
		if edit[2] <= limit then
			source = source:sub(1, edit[1]) .. edit[3] .. source:sub(edit[2] + 1)
			limit = edit[1]
		end
	end

	local lines = {}
	for line in (source .. "\n"):gmatch("(.-)\n") do
		if not line:find(DELETED, 1, true) or line:gsub(DELETED, ""):find("%S") then
			lines[#lines + 1] = (line:gsub(DELETED, ""))
		end
	end
	return table.concat(lines, "\n")
end

return M
