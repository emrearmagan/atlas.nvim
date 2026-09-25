local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

---@param buf integer
---@param callbacks { search: fun(), next_page: fun(), previous_page: fun(), delete: (fun())|nil }
function M.setup(buf, callbacks)
	local actions = {
		{ "ui.search", "Find branch", callbacks.search },
		{ "ui.next_page", "Next branch page", callbacks.next_page },
		{ "ui.previous_page", "Previous branch page", callbacks.previous_page },
	}
	if callbacks.delete then
		table.insert(actions, { "ui.delete", "Delete branch", callbacks.delete })
	end
	local items = {}
	for _, action in ipairs(actions) do
		local keys = resolver.resolve(action[1])
		if keys then
			table.insert(items, {
				key = #keys == 1 and keys[1] or keys,
				desc = action[2],
				opts = { nowait = true, silent = true },
				callback = action[3],
			})
		end
	end
	help.register("Branches", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action in ipairs({ "ui.search", "ui.next_page", "ui.previous_page", "ui.delete" }) do
		local keys = resolver.resolve(action)
		if keys then
			table.insert(items, { key = #keys == 1 and keys[1] or keys })
		end
	end
	help.remove("Branches", items, { buffer = buf })
end

return M
