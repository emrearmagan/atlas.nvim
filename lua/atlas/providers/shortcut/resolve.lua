local M = {}

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil or parsed.host ~= "app.shortcut.com" then
		return nil, nil
	end

	local workspace, raw_number, tail = parsed.path:match("^/([^/]+)/story/(%d+)(.*)$")
	local number = tonumber(raw_number)
	if workspace == nil or number == nil or number < 1 or (tail ~= "" and not tail:match("^/[^/]+$")) then
		return nil, "Unsupported Shortcut URL. Expected /<workspace>/story/<id>[/title]"
	end

	return {
		provider = "shortcut",
		domain = "issues",
		entity = "issue",
		url = value,
		host = parsed.host,
		workspace = workspace,
		number = number,
		id = number,
		issue_key = tostring(number),
	}
end

return M
