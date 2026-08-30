local M = {}

---@param v any
---@return table|nil
function M.as_table(v)
	if type(v) == "table" then
		return v
	end
	return nil
end

---@param value string
---@return string
function M.url_encode(value)
	return (value:gsub("([^%w%-_.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

return M
