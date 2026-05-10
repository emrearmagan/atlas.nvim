---@class GitHubProviderRepoPanel : PullsProviderRepoPanel
local M = {}

local icons = require("atlas.ui.shared.icons")

---@return PullsRepoPanelTab[]
function M.tabs()
	return {
		{
			key = "overview",
			label = "Overview",
			icon = icons.general("overview"),
			mod = require("atlas.pulls.ui.panel.repo.tabs.overview"),
		},
		{
			key = "issues",
			label = "Issues",
			icon = icons.issues("issue"),
			mod = require("atlas.pulls.providers.github.ui.repo_panel.issues"),
		},
		{
			key = "branches",
			label = "Branches",
			icon = icons.pulls("branch"),
			mod = require("atlas.pulls.ui.panel.repo.tabs.branches"),
		},
		{
			key = "tags",
			label = "Tags",
			icon = icons.pulls("tag"),
			mod = require("atlas.pulls.ui.panel.repo.tabs.tags"),
		},
	}
end

return M
