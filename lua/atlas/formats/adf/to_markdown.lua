local M = {}

local emoji_shortname_map = {
	[":check_mark:"] = "",
	[":white_check_mark:"] = "",
	[":x:"] = "",
	[":warning:"] = "",
	[":information_source:"] = "",
	[":hourglass_flowing_sand:"] = "",
	[":rocket:"] = "",
	[":smile:"] = "",
}

local status_color_map = {
	blue = "",
	green = "",
	yellow = "",
	red = "",
	neutral = "",
}

local panel_type_map = {
	info = "NOTE",
	note = "NOTE",
	warning = "WARNING",
	error = "CAUTION",
	success = "TIP",
}

local function collect_children(node, convert_node)
	local parts = {}
	for _, child in ipairs(node.content or {}) do
		table.insert(parts, convert_node(child))
	end
	return table.concat(parts)
end

local mark_handlers = {
	-- { "type": "strong" }
	strong = function(text)
		return "**" .. text .. "**"
	end,
	-- { "type": "em" }
	em = function(text)
		return "*" .. text .. "*"
	end,
	-- { "type": "code" }
	code = function(text)
		return "`" .. text .. "`"
	end,
	-- { "type": "strike" }
	strike = function(text)
		return "~~" .. text .. "~~"
	end,
	-- { "type": "link", "attrs": { "href": "https://example.com" } }
	link = function(text, attrs)
		return "[" .. text .. "](" .. (attrs and attrs.href or "") .. ")"
	end,
}

local function apply_marks(text, marks)
	if not marks then
		return text
	end

	local result = text
	for _, mark in ipairs(marks) do
		local handler = mark_handlers[mark.type]
		if handler then
			result = handler(result, mark.attrs)
		end
	end
	return result
end

local node_handlers = {}

-- { "type": "doc", "version": 1, "content": [...] }
node_handlers.doc = function(node, convert_node)
	local parts = {}
	for _, child in ipairs(node.content or {}) do
		table.insert(parts, convert_node(child))
	end
	return table.concat(parts, "\n\n")
end

-- { "type": "text", "text": "hello", "marks": [...] }
node_handlers.text = function(node)
	return apply_marks(node.text or "", node.marks)
end

-- { "type": "hardBreak" }
node_handlers.hardBreak = function()
	return "  \n"
end

-- { "type": "paragraph", "content": [...] }
node_handlers.paragraph = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "mention", "attrs": { "id": "abc123", "text": "@user" } }
node_handlers.mention = function(node)
	local attrs = type(node.attrs) == "table" and node.attrs or {}
	local mention_id = tostring(attrs.id or "")
	local mention_text = tostring(attrs.text or "")

	if mention_text == "" then
		return ""
	end

	if mention_id ~= "" then
		return string.format("[%s](atlas-mention:%s)", mention_text, mention_id)
	end

	return mention_text
end

-- { "type": "emoji", "attrs": { "shortName": ":smile:" } }
node_handlers.emoji = function(node)
	local attrs = type(node.attrs) == "table" and node.attrs or {}
	if type(attrs.shortName) == "string" and attrs.shortName ~= "" then
		return emoji_shortname_map[attrs.shortName] or attrs.shortName
	end
	return ""
end

-- { "type": "inlineCard", "attrs": { "url": "https://jira.example.com/browse/PROJ-123" } }
-- { "type": "blockCard", "attrs": { "url": "..." } }
-- { "type": "embedCard", "attrs": { "url": "..." } }
local function render_card(node)
	local url = node.attrs and node.attrs.url or ""
	local label = url:match("/browse/([^/]+)$") or url
	return "[" .. label .. "](" .. url .. ")"
end

node_handlers.inlineCard = render_card
node_handlers.blockCard = render_card
node_handlers.embedCard = render_card

-- { "type": "status", "attrs": { "text": "In Progress", "color": "yellow" } }
node_handlers.status = function(node)
	local color = node.attrs and node.attrs.color or "neutral"
	local text = node.attrs and node.attrs.text or ""
	return (status_color_map[color] or "") .. " " .. text
end

-- { "type": "date", "attrs": { "timestamp": "1609459200000" } }
node_handlers.date = function(node)
	local attrs = type(node.attrs) == "table" and node.attrs or {}
	local timestamp = tostring(attrs.timestamp or "")
	if timestamp == "" then
		return ""
	end

	local milliseconds = tonumber(timestamp)
	if milliseconds == nil then
		return "[date](atlas-date:" .. timestamp .. ")"
	end

	local seconds = math.floor(milliseconds / 1000)
	local label = os.date("!%Y-%m-%d", seconds) or "date"

	return "[" .. label .. "](atlas-date:" .. timestamp .. ")"
end

-- { "type": "listItem", "content": [{ "type": "paragraph", ... }] }
node_handlers.listItem = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "bulletList", "content": [{ "type": "listItem", ... }] }
node_handlers.bulletList = function(node, convert_node)
	local items = {}
	for _, item in ipairs(node.content or {}) do
		table.insert(items, "* " .. collect_children(item, convert_node))
	end
	return table.concat(items, "\n")
end

-- { "type": "orderedList", "content": [{ "type": "listItem", ... }] }
node_handlers.orderedList = function(node, convert_node)
	local items = {}
	for i, item in ipairs(node.content or {}) do
		table.insert(items, i .. ". " .. collect_children(item, convert_node))
	end
	return table.concat(items, "\n")
end

-- { "type": "taskList", "content": [{ "type": "taskItem", "attrs": { "state": "DONE" }, ... }] }
node_handlers.taskList = function(node, convert_node)
	local items = {}
	for _, item in ipairs(node.content or {}) do
		local checkbox = "[ ]"
		if item.attrs and item.attrs.state == "DONE" then
			checkbox = "[x]"
		end
		table.insert(items, "- " .. checkbox .. " " .. collect_children(item, convert_node))
	end
	return table.concat(items, "\n")
end

-- { "type": "taskItem", "attrs": { "localId": "...", "state": "TODO" }, "content": [...] }
node_handlers.taskItem = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "blockquote", "content": [{ "type": "paragraph", ... }] }
node_handlers.blockquote = function(node, convert_node)
	local content = collect_children(node, convert_node)
	local lines = {}
	for line in content:gmatch("[^\n]+") do
		table.insert(lines, "> " .. line)
	end
	return table.concat(lines, "\n")
end

-- { "type": "panel", "attrs": { "panelType": "info" }, "content": [...] }
node_handlers.panel = function(node, convert_node)
	local panel_type = node.attrs and node.attrs.panelType or "info"
	local content = collect_children(node, convert_node)

	local lines = {}
	for line in content:gmatch("[^\n]+") do
		table.insert(lines, "> " .. line)
	end

	return "> [!" .. (panel_type_map[panel_type] or "NOTE") .. "]\n" .. table.concat(lines, "\n")
end

-- { "type": "heading", "attrs": { "level": 2 }, "content": [...] }
node_handlers.heading = function(node, convert_node)
	local level = node.attrs and node.attrs.level or 1
	return string.rep("#", level) .. " " .. collect_children(node, convert_node)
end

-- { "type": "codeBlock", "attrs": { "language": "lua" }, "content": [{ "type": "text", "text": "..." }] }
node_handlers.codeBlock = function(node)
	local lang = node.attrs and node.attrs.language or ""
	local content = {}
	for _, child in ipairs(node.content or {}) do
		if child.type == "text" then
			table.insert(content, child.text)
		end
	end
	return "```" .. lang .. "\n" .. table.concat(content) .. "\n```"
end

-- File media uses a Media Services ID; external images include a URL.
node_handlers.media = function(node)
	local attrs = node.attrs or {}
	if attrs.url then
		return "![" .. (attrs.alt or "") .. "](" .. attrs.url .. ")"
	end
	-- No media link yet. We'd need to fetch the issue's attachment metadata
	-- and pass it to the parser to map the media ID to a URL.
	return "[" .. (attrs.alt or "Attachment") .. "]"
end

node_handlers.mediaInline = node_handlers.media
node_handlers.mediaGroup = node_handlers.doc

-- { "type": "mediaSingle", "content": [{ "type": "media", ... }] }
node_handlers.mediaSingle = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "rule" }
node_handlers.rule = function()
	return "---"
end

-- { "type": "tableCell", "content": [{ "type": "paragraph", ... }] }
node_handlers.tableCell = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "tableHeader", "content": [{ "type": "paragraph", ... }] }
node_handlers.tableHeader = function(node, convert_node)
	return collect_children(node, convert_node)
end

-- { "type": "tableRow", "content": [{ "type": "tableCell"|"tableHeader", ... }] }
node_handlers.tableRow = function(node, convert_node)
	local cells = {}
	for _, cell in ipairs(node.content or {}) do
		table.insert(cells, convert_node(cell))
	end
	return "| " .. table.concat(cells, " | ") .. " |"
end

-- { "type": "table", "content": [{ "type": "tableRow", ... }] }
node_handlers.table = function(node, convert_node)
	local rows = {}
	for i, row in ipairs(node.content or {}) do
		table.insert(rows, convert_node(row))
		if i == 1 then
			local cols = #(row.content or {})
			local sep = {}
			for _ = 1, cols do
				table.insert(sep, "---")
			end
			table.insert(rows, "| " .. table.concat(sep, " | ") .. " |")
		end
	end
	return table.concat(rows, "\n")
end

local function convert_node(node)
	local handler = node_handlers[node.type]
	if handler then
		return handler(node, convert_node)
	end

	return ""
end

---@param document any
---@return string
function M.to_markdown(document)
	if type(document) ~= "table" then
		return ""
	end

	if document.type ~= "doc" then
		local parts = {}
		for _, node in ipairs(document) do
			table.insert(parts, convert_node(node))
		end
		return table.concat(parts, "\n\n")
	end

	return convert_node(document)
end

return M
