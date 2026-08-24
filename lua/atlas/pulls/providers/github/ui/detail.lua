---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.components.header")

local MAX_HASH_LEN = 12

---@param hex string
---@return string
local function label_hl(hex)
	local name = string.format("AtlasGHLabel_%s", hex)
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

-- Detail

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end

	local logins = {}
	for _, assignee in ipairs(details.assignees or {}) do
		local login = assignee.username
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_field(logins) }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, details, _loading)
	local chips = {}
	local data = details or pr

	local hash = tostring(data.source and data.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	for _, lbl in ipairs((details and details.labels) or {}) do
		local name = tostring(lbl.name or "")
		if name ~= "" then
			local color = tostring(lbl.color or "")
			local hl = color ~= "" and label_hl(color) or "AtlasTabInactive"
			table.insert(chips, { label = name, hl = hl })
		end
	end

	return chips
end

-- Tabs

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
