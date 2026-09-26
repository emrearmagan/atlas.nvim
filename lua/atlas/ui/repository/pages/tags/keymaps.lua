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
		callback = callbacks.refresh,
		opts = { nowait = true, silent = true },
	}
	local actions = {
		{ resolver.resolve("ui.next_page"), "Next page", callbacks.next_page },
		{ resolver.resolve("ui.previous_page"), "Previous page", callbacks.previous_page },
		{ resolver.resolve("ui.search"), "Search tags", callbacks.search },
		{
			vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			"Toggle tag details",
			callbacks.select,
		},
		{ resolver.resolve("pulls.open_diff"), "Open diff", callbacks.diff },
		{ resolver.resolve("ui.show_details"), "Show tag details", callbacks.details },
		{ resolver.resolve("ui.open_in_browser"), "Open tag in browser", callbacks.browser },
		{ resolver.resolve("ui.copy_id"), "Copy commit SHA", callbacks.copy },
		{ resolver.resolve("ui.copy_url"), "Copy tag URL", callbacks.copy_url },
	}
	local items = { refresh }
	for _, action in ipairs(actions) do
		local keys = action[1]
		if keys and #keys > 0 then
			table.insert(items, {
				key = keys,
				desc = action[2],
				callback = action[3],
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
