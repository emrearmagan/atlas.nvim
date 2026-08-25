local M = {}

local MODULE = "atlas.providers.github.client"

---@param handlers { gh: function|nil, api: function|nil, delete_mem: function|nil } stubs for the client entry points
function M.install(handlers)
	handlers = handlers or {}
	package.loaded[MODULE] = nil
	package.preload[MODULE] = function()
		return {
			gh = handlers.gh or function() end,
			api = handlers.api or function() end,
			delete_mem = handlers.delete_mem or function() end,
		}
	end
end

function M.uninstall()
	package.preload[MODULE] = nil
	package.loaded[MODULE] = nil
end

return M
