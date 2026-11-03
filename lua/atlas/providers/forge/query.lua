local M = {}

---@class ForgeQueryToken
---@field raw string
---@field key string|nil
---@field value string|nil

---@param input string
---@return ForgeQueryToken[]|nil, string|nil
local function tokenize(input)
	local tokens, current = {}, {}
	local quoted, escaped = false, false
	local function append()
		if #current == 0 then
			return
		end
		local raw = table.concat(current)
		local key, value = raw:match("^([^:%s]+):(.*)$")
		if value and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
			value = value:sub(2, -2):gsub('\\([\\"])', "%1")
		end
		table.insert(tokens, { raw = raw, key = key, value = value })
		current = {}
	end
	for index = 1, #input do
		local char = input:sub(index, index)
		if escaped then
			escaped = false
		elseif char == "\\" and quoted then
			escaped = true
		elseif char == '"' then
			quoted = not quoted
		elseif char:match("%s") and not quoted then
			append()
			char = ""
		end
		if char ~= "" then
			table.insert(current, char)
		end
	end
	if quoted then
		return nil, "Unclosed quote in search query"
	end
	append()
	return tokens, nil
end

---@param value string|number|boolean
---@return string
local function quote(value)
	value = tostring(value)
	if value == "" or value:find('[%s"\\]') then
		return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
	end
	return value
end

---@param input string
---@param fields table<string, string>
---@return table|nil, string|nil
function M.parse(input, fields)
	local tokens, err = tokenize(input)
	if not tokens then
		return nil, err
	end
	local parsed, text = { states = {}, extra_params = {} }, {}
	for _, token in ipairs(tokens) do
		local key, value = token.key and token.key:lower(), token.value
		local field = fields[key]
		if key == "is" or field == "is" then
			table.insert(parsed.states, value)
		elseif key == "search" then
			table.insert(text, value)
		elseif key and key:match("^param%..+$") then
			parsed.extra_params[token.key:sub(7)] = value
		elseif field then
			parsed[field] = value
		else
			table.insert(text, token.raw)
		end
	end
	parsed.search = table.concat(text, " ")
	return parsed, nil
end

---@param parts string[]
---@param key string
---@param value string|number|boolean|nil
function M.append(parts, key, value)
	if value ~= nil and value ~= "" then
		table.insert(parts, key .. ":" .. quote(value))
	end
end

return M
