---@type PullsProviderRepoDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

---@return PullsRepoDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local issue_icon, issue_hl = icons.issues_provider("github", "issue")
	local branch_icon, branch_hl = icons.pulls("branch")
	local tag_icon, tag_hl = icons.pulls("tag")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.pulls.ui.repo_detail.tabs.overview"),
		},
		{
			key = "issues",
			label = "Issues",
			icon = { icon = issue_icon, hl_group = issue_hl },
			mod = require("atlas.pulls.ui.repo_detail.tabs.issues"),
		},
		{
			key = "branches",
			label = "Branches",
			icon = { icon = branch_icon, hl_group = branch_hl },
			mod = require("atlas.pulls.ui.repo_detail.tabs.branches"),
		},
		{
			key = "tags",
			label = "Tags",
			icon = { icon = tag_icon, hl_group = tag_hl },
			mod = require("atlas.pulls.ui.repo_detail.tabs.tags"),
		},
	}
end

return M
