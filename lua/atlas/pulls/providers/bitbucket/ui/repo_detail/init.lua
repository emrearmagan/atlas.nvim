---@type PullsProviderRepoDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

---@return PullsRepoDetailTab[]
function M.tabs()
	local overview_icon = icons.general("overview")
	local branch_icon = icons.pulls("branch")
	local tag_icon = icons.pulls("tag")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon },
			mod = require("atlas.pulls.ui.repo_detail.tabs.overview"),
		},
		{
			key = "branches",
			label = "Branches",
			icon = { icon = branch_icon },
			mod = require("atlas.pulls.ui.repo_detail.tabs.branches"),
		},
		{
			key = "tags",
			label = "Tags",
			icon = { icon = tag_icon },
			mod = require("atlas.pulls.ui.repo_detail.tabs.tags"),
		},
	}
end

return M
