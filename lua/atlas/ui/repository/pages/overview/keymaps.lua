local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param state RepositoryOverview
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	---@param buf integer
	---@return AtlasHelpKeyItem[]
	local function register(buf)
		local items = {}
		local refresh = resolver.resolve({ "ui.refresh", "ui.refresh_view" })
		if refresh then
			table.insert(items, {
				key = refresh.key,
				desc = refresh.desc,
				index = 80,
				callback = function()
					callbacks.load(state)
				end,
				opts = { nowait = true, silent = true },
			})
		end
		local open_in_browser = resolver.resolve("ui.open_in_browser")
		if open_in_browser then
			table.insert(items, {
				key = open_in_browser.key,
				desc = open_in_browser.desc,
				index = 4,
				callback = function()
					callbacks.open_in_browser(state)
				end,
				opts = { nowait = true, silent = true },
			})
		end

		help.register("General", items, { buffer = buf, index = 1 })
		return items
	end

	register(state.buf)
	state.keymaps = register(state.sidebar_buf)
end

return M
