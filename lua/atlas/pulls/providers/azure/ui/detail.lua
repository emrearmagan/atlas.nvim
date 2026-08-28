---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, _loading)
	local chips = {}
	for _, label in ipairs(details and details.labels or {}) do
		table.insert(chips, { label = label.name, hl = "AtlasTabInactive" })
	end
	return chips
end

---@return PullsDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.pulls.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.pulls.ui.detail.tabs.conversation"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = { icon = commit_icon, hl_group = commit_hl },
			mod = require("atlas.pulls.ui.detail.tabs.commits"),
		},
	}
end

return M
