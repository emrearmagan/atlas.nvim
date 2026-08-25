---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

local MAX_HASH_LEN = 12

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, _loading)
	---@cast details BitbucketPullRequestDetails|nil
	local fields = {}

	if details and details.close_source_branch ~= nil then
		local state_icon, state_icon_hl
		if details.close_source_branch then
			state_icon, state_icon_hl = icons.general("success")
		else
			state_icon, state_icon_hl = icons.general("error")
		end
		table.insert(fields, {
			label = "Close source",
			value = state_icon,
			hl = state_icon_hl,
		})
	end

	return fields
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, _details, _loading)
	local chips = {}

	local hash = pr.source.commit_hash
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
			key = "review",
			label = "Review",
			icon = { icon = review_icon, hl_group = review_hl },
			mod = require("atlas.pulls.ui.detail.tabs.review"),
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
