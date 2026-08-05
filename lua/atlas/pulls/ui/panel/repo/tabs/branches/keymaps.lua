local M = {}

local help = require("atlas.ui.popups.help")

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local provider = require("atlas.pulls.state").provider
	local repository = provider and provider.capabilities.repository
	if repository == nil or repository.delete_branch == nil then
		return
	end

	local tab = require("atlas.pulls.ui.panel.repo.tabs.branches")
	help.register("Branches", {
		{
			key = "d",
			desc = "Delete branch",
			opts = { nowait = true, silent = true },
			callback = function()
				tab.delete_current_branch(refresh)
			end,
		},
	}, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	help.remove("Branches", {
		{ key = "d" },
	}, { buffer = buf })
end

return M
