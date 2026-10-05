local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@type table<integer, AtlasHelpKeyItem[]>
local installed = {}

---@param buf integer
---@param sidebar_buf integer
---@param callbacks { search: fun(), refresh: fun(), next_page: fun(), previous_page: fun(), select: fun(), diff: fun(), details: fun(), browser: fun(), copy: fun(), copy_url: fun() }
function M.setup(buf, sidebar_buf, callbacks)
	M.clear(buf)
	M.clear(sidebar_buf)
	local refresh = {
		key = resolver.resolve("ui.refresh") or {},
		desc = "Refresh tags",
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
		{ key = resolver.resolve("ui.search"), desc = "Search tags", callback = callbacks.search, index = 20 },
		{
			key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			desc = "Toggle tag details",
			callback = callbacks.select,
			index = 30,
		},
		{ key = resolver.resolve("pulls.open_diff"), desc = "Open diff", callback = callbacks.diff, index = 31 },
		{
			key = resolver.resolve("ui.show_details"),
			desc = "Show tag details",
			callback = callbacks.details,
			index = 32,
		},
		{
			key = resolver.resolve("ui.open_in_browser"),
			desc = "Open tag in browser",
			callback = callbacks.browser,
			index = 33,
		},
		{ key = resolver.resolve("ui.copy_id"), desc = "Copy commit SHA", callback = callbacks.copy, index = 40 },
		{ key = resolver.resolve("ui.copy_url"), desc = "Copy tag URL", callback = callbacks.copy_url, index = 41 },
	}
	local items = { refresh }
	for _, action in ipairs(actions) do
		local keys = action.key
		if keys and #keys > 0 then
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
	help.register("Tags", items, { buffer = buf })
	installed[sidebar_buf] = { refresh }
	help.register("Tags", installed[sidebar_buf], { buffer = sidebar_buf })
end

---@param buf integer
function M.clear(buf)
	if installed[buf] then
		help.remove("Tags", installed[buf], { buffer = buf })
		installed[buf] = nil
	end
end

return M
