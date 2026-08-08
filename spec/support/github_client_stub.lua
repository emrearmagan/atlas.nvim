-- Shared stub for `atlas.providers.github.client` so specs can drive the `gh`/`api`
-- entry points without spawning the real CLI.
--
-- Specs preload the client through this single module rather than assigning
-- `package.preload` themselves; besides removing the duplication, it keeps the Lua
-- language server from reporting a `duplicate-set-field` warning for the same field
-- being written from several spec files.

local M = {}

local MODULE = "atlas.providers.github.client"

---@param handlers { gh: function|nil, api: function|nil } stubs for the client entry points
function M.install(handlers)
	handlers = handlers or {}
	package.loaded[MODULE] = nil
	package.preload[MODULE] = function()
		local client = {
			gh = handlers.gh or function() end,
			api = handlers.api or function() end,
			get_mem = function()
				return nil, false
			end,
			set_mem = function() end,
		}
		return { pulls = client, issues = client }
	end
end

---Drop the stub so the next `require` sees the real module again.
function M.uninstall()
	package.preload[MODULE] = nil
	package.loaded[MODULE] = nil
end

return M
