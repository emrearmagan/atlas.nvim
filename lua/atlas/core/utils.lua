local M = {}

---@param v any
---@return table|nil
function M.as_table(v)
	if type(v) == "table" then
		return v
	end
	return nil
end

---@param input string
---@return string[]
function M.split_tokens(input)
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #input do
		local char = input:sub(i, i)
		if char == '"' then
			quoted = not quoted
			table.insert(current, char)
		elseif char:match("%s") and not quoted then
			if #current > 0 then
				table.insert(tokens, table.concat(current))
				current = {}
			end
		else
			table.insert(current, char)
		end
	end
	if #current > 0 then
		table.insert(tokens, table.concat(current))
	end
	return tokens
end

---@param value string
---@return string
function M.url_encode(value)
	return (value:gsub("([^%w%-_.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

return M
