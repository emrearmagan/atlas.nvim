local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param buf integer
---@param actions table[]
---@return table<string, AtlasHelpKeyItem[]>
local function register(buf, actions)
	local groups = { General = {}, Filters = {} }
	for _, action in ipairs(actions) do
		if action.key and #action.key > 0 then
			table.insert(groups[action.group or "General"], {
				key = action.key,
				desc = action.desc,
				index = action.index,
				callback = action.callback,
				opts = { silent = true, nowait = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	return groups
end

---@param state RepositoryBuilds
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh builds",
			callback = function()
				callbacks.load(state)
			end,
			index = 80,
		},
		{
			key = { "b" },
			desc = "Change build branch",
			group = "Filters",
			callback = function()
				callbacks.change_branch(state)
			end,
			index = 1,
		},
	}

	state.keymaps = register(state.sidebar_buf, actions)
	register(
		state.buf,
		vim.list_extend(actions, {
			{
				key = resolver.resolve("ui.select"),
				desc = "Open build and logs",
				callback = function()
					callbacks.open_build(state)
				end,
				index = 1,
			},
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open build in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
		})
	)
end

return M
