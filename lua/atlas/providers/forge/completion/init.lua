local M = {}

---@param service ForgeService
---@return table<string, AtlasCompletionSource>
function M.new(service)
	return {
		users = require("atlas.providers.forge.completion.users").new(service),
	}
end

return M
