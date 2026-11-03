local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param buf integer
---@param actions table[]
---@return table<string, AtlasHelpKeyItem[]>
local function register(buf, actions)
	local groups = { General = {} }
	for _, action in ipairs(actions) do
		if action.key and #action.key > 0 then
			table.insert(groups.General, {
				key = action.key,
				desc = action.desc,
				index = action.index,
				callback = action.callback,
				opts = { silent = true, nowait = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	return groups
end

---@param state RepositoryDeployments
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = resolver.resolve("ui.refresh"),
			desc = "Refresh deployments",
			callback = function()
				callbacks.load(state)
			end,
			index = 80,
		},
	}

	state.keymaps = register(state.sidebar_buf, actions)
	register(
		state.buf,
		vim.list_extend(actions, {
			{
				key = resolver.resolve("ui.toggle_fold"),
				desc = "Toggle environment history",
				callback = function()
					callbacks.toggle_history(state)
				end,
				index = 5,
			},
			{
				key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.show_details") or {}),
				desc = "Open build",
				callback = function()
					callbacks.open_build(state)
				end,
				index = 1,
			},
			{
				key = resolver.resolve("ui.open_actions"),
				desc = "Deployment actions",
				callback = function()
					callbacks.show_actions(state)
				end,
				index = 11,
			},
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open deployment in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
		})
	)
end

return M
