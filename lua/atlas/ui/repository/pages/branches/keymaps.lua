local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param buf integer
---@param actions table[]
---@return table<string, AtlasHelpKeyItem[]>
local function register(buf, actions)
	local groups = { General = {}, Filters = {} }
	for _, action in ipairs(actions) do
		if action.key and #action.key > 0 and action.callback then
			table.insert(groups[action.group or "General"], {
				key = action.key,
				desc = action.desc,
				index = action.index,
				callback = action.callback,
				opts = { nowait = true, silent = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	return groups
end

---@param state RepositoryBranches
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local refresh = {
		key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
		desc = "Refresh branches",
		callback = function()
			callbacks.load(state)
		end,
		index = 80,
	}

	state.keymaps = register(state.sidebar_buf, { refresh })
	register(state.buf, {
		refresh,
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next page",
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous page",
			callback = function()
				callbacks.previous_page(state)
			end,
			index = 15,
		},
		{
			key = resolver.resolve("ui.search"),
			desc = "Search branches",
			group = "Filters",
			callback = function()
				callbacks.search(state)
			end,
			index = 1,
		},
		{
			key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			desc = "Toggle branch history",
			callback = function()
				callbacks.toggle_history(state)
			end,
			index = 2,
		},
		{
			key = resolver.resolve("pulls.open_diff"),
			desc = "Open branch or commit diff",
			callback = function()
				callbacks.open_diff(state)
			end,
			index = 3,
		},
		{
			key = resolver.resolve("ui.show_details"),
			desc = "Show branch or commit details",
			callback = function()
				callbacks.show_details(state)
			end,
			index = 4,
		},
		{
			key = resolver.resolve("ui.open_actions"),
			desc = "Open branch actions",
			callback = function()
				callbacks.open_actions(state)
			end,
			index = 1,
		},
		{
			key = resolver.resolve("pulls.checkout"),
			desc = "Checkout branch",
			callback = function()
				callbacks.checkout(state)
			end,
			index = 20,
		},
		{
			key = resolver.resolve("ui.delete"),
			desc = "Delete branch",
			callback = state.repository.delete_branch and function()
				callbacks.delete(state)
			end,
			index = 90,
		},
	})
end

return M
