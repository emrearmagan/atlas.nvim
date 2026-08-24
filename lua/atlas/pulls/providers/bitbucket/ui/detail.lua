---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

local MAX_HASH_LEN = 12

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailHeaderRow[]
function M.header_rows(pr, _details, _loading)
	---@cast pr BitbucketPullRequest
	local rows = {}

	if pr.close_source_branch ~= nil then
		local state_icon, state_icon_hl
		if pr.close_source_branch then
			state_icon, state_icon_hl = icons.general("success")
		else
			state_icon, state_icon_hl = icons.general("error")
		end
		table.insert(rows, {
			k1 = "Close source:",
			v1 = state_icon,
			v1_hl = state_icon_hl,
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		})
	end

	return rows
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, _details, _loading)
	local chips = {}

	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	return chips
end

---@return PullsDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local review_icon, review_hl = icons.pulls("review")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.pulls.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.pulls.ui.detail.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = review_icon,
			icon_hl = review_hl,
			mod = require("atlas.pulls.ui.detail.tabs.review"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = commit_icon,
			icon_hl = commit_hl,
			mod = require("atlas.pulls.ui.detail.tabs.commits"),
		},
	}
end

return M
