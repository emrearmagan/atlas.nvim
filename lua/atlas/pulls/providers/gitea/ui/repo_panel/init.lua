---@class GiteaProviderRepoPanel : PullsProviderRepoPanel
local M = {}

local icons = require("atlas.ui.shared.icons")

---@return PullsRepoPanelTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local issue_icon, issue_hl = icons.issues_provider("gitea", "issue")
	local branch_icon, branch_hl = icons.pulls("branch")
	local tag_icon, tag_hl = icons.pulls("tag")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.pulls.ui.panel.repo.tabs.overview"),
		},
		{
			key = "issues",
			label = "Issues",
			icon = issue_icon,
			icon_hl = issue_hl,
			mod = require("atlas.pulls.ui.panel.repo.tabs.issues"),
		},
		{
			key = "branches",
			label = "Branches",
			icon = branch_icon,
			icon_hl = branch_hl,
			mod = require("atlas.pulls.ui.panel.repo.tabs.branches"),
		},
		{
			key = "tags",
			label = "Tags",
			icon = tag_icon,
			icon_hl = tag_hl,
			mod = require("atlas.pulls.ui.panel.repo.tabs.tags"),
		},
	}
end

return M
