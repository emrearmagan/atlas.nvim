local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local provider = require("atlas.pulls.ui.repo_detail.state").provider
	local repository = provider and provider.capabilities.repository
	if repository == nil or repository.delete_branch == nil then
		return
	end

	local tab = require("atlas.pulls.ui.repo_detail.tabs.branches")
	local keys = resolver.resolve("ui.delete")
	local items = {}
	if keys then
		table.insert(items, {
			key = #keys == 1 and keys[1] or keys,
			desc = "Delete branch",
			opts = { nowait = true, silent = true },
			callback = function()
				tab.delete_current_branch(refresh)
			end,
		})
	end
	help.register("Branches", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local keys = resolver.resolve("ui.delete")
	local items = {}
	if keys then
		table.insert(items, { key = #keys == 1 and keys[1] or keys })
	end
	help.remove("Branches", items, { buffer = buf })
end

return M
