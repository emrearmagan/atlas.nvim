local M = {}

local url = require("atlas.providers.url")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	local reference = value:upper():match("^([A-Z][A-Z0-9_]*%-%d+)$")
	local base = url.configured_base("jira")
	if reference then
		if base == nil then
			return nil, "Missing Jira base_url"
		end
		local base_url = url.base_url("jira", base.host, nil)
		return {
			provider = "jira",
			domain = "issues",
			entity = "issue",
			host = base.host,
			issue_key = reference,
			url = base_url .. "/browse/" .. reference,
		}
	end

	if parsed == nil then
		return nil, nil
	end
	local path = url.path(parsed, base)
	if path == nil then
		return nil, nil
	end

	local issue_key, tail = path:match("^/browse/([A-Z][A-Z0-9_]*%-%d+)(.*)$")
	if issue_key == nil or not url.valid_tail(tail) then
		return nil, "Unsupported Jira URL. Expected a /browse/KEY issue URL"
	end

	return {
		provider = "jira",
		domain = "issues",
		entity = "issue",
		url = value,
		host = parsed.host,
		issue_key = issue_key,
	}
end

return M
