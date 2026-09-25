local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@type table<integer, AtlasHelpKeyItem[]>
local installed = {}

---@param buf integer
---@param navigation_buf integer
---@param callbacks { search: fun(), refresh: fun(), next_page: fun(), previous_page: fun(), select: fun(), diff: fun(), details: fun(), actions: fun(), checkout: fun(), delete?: fun() }
function M.setup(buf, navigation_buf, callbacks)
	M.clear(buf)
	M.clear(navigation_buf)
	local refresh = {
		key = resolver.resolve("ui.refresh") or {},
		desc = "Refresh branches",
		callback = callbacks.refresh,
		opts = { nowait = true, silent = true },
	}
	local actions = {
		{ resolver.resolve("ui.next_page"), "Next page", callbacks.next_page },
		{ resolver.resolve("ui.previous_page"), "Previous page", callbacks.previous_page },
		{ resolver.resolve("ui.search"), "Search branches", callbacks.search },
		{
			vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			"Toggle branch history",
			callbacks.select,
		},
		{ resolver.resolve("pulls.open_diff"), "Open branch or commit diff", callbacks.diff },
		{ resolver.resolve("pulls.checkout"), "Checkout branch", callbacks.checkout },
		{ resolver.resolve("ui.show_details"), "Show branch or commit details", callbacks.details },
		{ resolver.resolve("ui.open_actions"), "Open branch actions", callbacks.actions },
		{ resolver.resolve("ui.delete"), "Delete branch", callbacks.delete },
	}
	local items = { refresh }
	for _, action in ipairs(actions) do
		local keys = action[1]
		if keys and #keys > 0 and action[3] then
			table.insert(items, {
				key = keys,
				desc = action[2],
				callback = action[3],
				opts = { nowait = true, silent = true },
			})
		end
	end
	installed[buf] = items
	help.register("Branches", items, { buffer = buf })
	installed[navigation_buf] = { refresh }
	help.register("Branches", installed[navigation_buf], { buffer = navigation_buf })
end

---@param buf integer
function M.clear(buf)
	if installed[buf] then
		help.remove("Branches", installed[buf], { buffer = buf })
		installed[buf] = nil
	end
end

return M
