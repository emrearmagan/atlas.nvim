---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.components.header")

local MAX_HASH_LEN = 12

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	---@cast details GiteaPullRequestDetails|nil
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end
	local logins = {}
	for _, assignee in ipairs(details.assignees or {}) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end
	return { header.assignee_field(logins) }
end

---@param hex string
---@return string
local function label_hl(hex)
	hex = tostring(hex or ""):gsub("^#", "")
	if not hex:match("^%x%x%x%x%x%x$") then
		return "AtlasTabInactive"
	end
	local name = "AtlasGiteaLabel_" .. hex
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, details, _loading)
	---@cast pr GiteaPullRequest
	---@cast details GiteaPullRequestDetails|nil
	local chips = {}
	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		table.insert(chips, { label = hash:sub(1, MAX_HASH_LEN), hl = "AtlasTabInactive" })
	end
	for _, label in ipairs((details and details.labels) or {}) do
		if tostring(label.name or "") ~= "" then
			table.insert(chips, { label = label.name, hl = label_hl(label.color or "") })
		end
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
