local M = {}

---Return nil if v is vim.NIL or nil, else v.
---@param v any
---@return any|nil
function M.nilify(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
end

---Convert v to a string, returning nil for vim.NIL/nil.
---@param v any
---@return string|nil
function M.safe_str(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return tostring(v)
end

---Return v if it's a table, otherwise an empty table.
---@param v any
---@return table
function M.safe_table(v)
	if v == nil or v == vim.NIL or type(v) ~= "table" then
		return {}
	end
	return v
end

---Return whether v is a decoded JSON list. HTTP status metadata added by
---atlas.core.http is ignored when checking the array keys.
---@param v any
---@return boolean
function M.is_list(v)
	if type(v) ~= "table" then
		return false
	end
	for key in pairs(v) do
		if key ~= "__http_status" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
			return false
		end
	end
	return true
end

return M
