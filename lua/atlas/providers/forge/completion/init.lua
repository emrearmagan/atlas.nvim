local M = {}

---@param service ForgeService
---@return table<string, AtlasCompletionSource>
function M.new(service)
	return {
		users = require("atlas.providers.forge.completion.users").new(service),
		references = require("atlas.providers.forge.completion.references").new(service),
	}
end

return M
