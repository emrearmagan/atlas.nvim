local M = {}

local help = require("atlas.ui.popups.help")

---@param id GitHubActionId|string
---@param pr PullRequest
local function run_action(id, pr)
	local actions = require("atlas.pulls.providers.github.actions")
	actions.run(id, { pr = pr, source = "panel" }, function(result, _)
		if result ~= nil and result.changed_pr then
			local controller = require("atlas.pulls.ui.main.controller")
			controller.refresh_pr(pr)
		end
	end)
end

---@param buf integer
function M.register(buf)
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local items = {
		{
			key = "gr",
			desc = "Edit reviewers",
			opts = { nowait = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				run_action("edit_reviewers", pr)
			end,
		},
		{
			key = "ga",
			desc = "Edit assignees",
			opts = { nowait = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				run_action("edit_assignees", pr)
			end,
		},
	}

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	help.remove("Panel", { { key = "gr" }, { key = "ga" } }, { buffer = buf })
end

return M
