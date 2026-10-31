local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param state RepositoryOverview
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	---@param buf integer
	---@return AtlasHelpKeyItem[]
	local function register(buf)
		local items = {
			{
				key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
				desc = "Reload overview",
				index = 80,
				callback = function()
					callbacks.load(state)
				end,
				opts = { nowait = true, silent = true },
			},
			{
				key = resolver.resolve("ui.open_in_browser") or {},
				desc = "Open repository in browser",
				index = 4,
				callback = function()
					callbacks.open_in_browser(state)
				end,
				opts = { nowait = true, silent = true },
			},
		}

		help.register("General", items, { buffer = buf, index = 1 })
		return items
	end

	register(state.buf)
	state.keymaps = register(state.sidebar_buf)
end

return M
