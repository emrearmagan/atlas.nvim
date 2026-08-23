---@type PullsProviderRepoDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

---@return PullsRepoDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local branch_icon, branch_hl = icons.pulls("branch")
	local tag_icon, tag_hl = icons.pulls("tag")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.pulls.ui.repo_detail.tabs.overview"),
		},
		{
			key = "branches",
			label = "Branches",
			icon = branch_icon,
			icon_hl = branch_hl,
			mod = require("atlas.pulls.ui.repo_detail.tabs.branches"),
		},
		{
			key = "tags",
			label = "Tags",
			icon = tag_icon,
			icon_hl = tag_hl,
			mod = require("atlas.pulls.ui.repo_detail.tabs.tags"),
		},
	}
end

return M
