local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@type table<integer, AtlasHelpKeyItem[]>
local installed = {}

---@param buf integer
---@param sidebar_buf integer
---@param callbacks { search: fun(), refresh: fun(), next_page: fun(), previous_page: fun(), select: fun(), diff: fun(), details: fun(), actions: fun(), checkout: fun(), delete?: fun() }
function M.setup(buf, sidebar_buf, callbacks)
	M.clear(buf)
	M.clear(sidebar_buf)
	local refresh = {
		key = resolver.resolve("ui.refresh") or {},
		desc = "Refresh branches",
		index = 25,
		callback = callbacks.refresh,
		opts = { nowait = true, silent = true },
	}
	local actions = {
		{ key = resolver.resolve("ui.next_page"), desc = "Next page", callback = callbacks.next_page, index = 11 },
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous page",
			callback = callbacks.previous_page,
			index = 10,
		},
		{ key = resolver.resolve("ui.search"), desc = "Search branches", callback = callbacks.search, index = 20 },
		{
			key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			desc = "Toggle branch history",
			callback = callbacks.select,
			index = 30,
		},
		{
			key = resolver.resolve("pulls.open_diff"),
			desc = "Open branch or commit diff",
			callback = callbacks.diff,
			index = 31,
		},
		{
			key = resolver.resolve("pulls.checkout"),
			desc = "Checkout branch",
			callback = callbacks.checkout,
			index = 60,
		},
		{
			key = resolver.resolve("ui.show_details"),
			desc = "Show branch or commit details",
			callback = callbacks.details,
			index = 32,
		},
		{
			key = resolver.resolve("ui.open_actions"),
			desc = "Open branch actions",
			callback = callbacks.actions,
			index = 50,
		},
		{ key = resolver.resolve("ui.delete"), desc = "Delete branch", callback = callbacks.delete, index = 61 },
	}
	local items = { refresh }
	for _, action in ipairs(actions) do
		local keys = action.key
		if keys and #keys > 0 and action.callback then
			table.insert(items, {
				key = keys,
				desc = action.desc,
				index = action.index,
				callback = action.callback,
				opts = { nowait = true, silent = true },
			})
		end
	end
	installed[buf] = items
	help.register("Branches", items, { buffer = buf })
	installed[sidebar_buf] = { refresh }
	help.register("Branches", installed[sidebar_buf], { buffer = sidebar_buf })
end

---@param buf integer
function M.clear(buf)
	if installed[buf] then
		help.remove("Branches", installed[buf], { buffer = buf })
		installed[buf] = nil
	end
end

return M
