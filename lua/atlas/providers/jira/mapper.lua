local M = {}

local service = require("atlas.providers.jira.client")
local json = require("atlas.core.json")

---@param raw_user any Decoded API value.
---@return AtlasUser|nil
function M.to_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end

	return {
		id = json.safe_str(raw_user[service.is_server() and "name" or "accountId"]) or "",
		name = json.safe_str(raw_user.displayName) or "",
		username = json.safe_str(raw_user.name),
	}
end

return M
