---@class GiteaProviderPRPanel : PullsProviderPRPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.panel.components.header")
local pullrequests = require("atlas.pulls.providers.gitea.api.pullrequests")

local MAX_HASH_LEN = 12

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsPanelHeaderRow[]
function M.header_rows(_pr, details, loading)
	if details == nil then
		return loading and { header.loading_assignee_row() } or {}
	end
	local logins = {}
	for _, assignee in ipairs(details.assignees or {}) do
		local login = assignee.username
		if login ~= "" then
			table.insert(logins, login)
		end
	end
	local rows = { header.assignee_row(logins) }
	return rows
end

---@param hex string
---@return string
local function label_hl(hex)
	hex = hex:gsub("^#", "")
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
---@return PullsPanelChip[]
function M.chips(pr, details, _loading)
	local chips = {}
	local hash = pr.source.commit_hash
	if hash ~= "" then
		table.insert(chips, { label = hash:sub(1, MAX_HASH_LEN), hl = "AtlasTabInactive" })
	end
	for _, label in ipairs((details and details.labels) or {}) do
		if label.name ~= "" then
			table.insert(chips, { label = label.name, hl = label_hl(label.color or "") })
		end
	end
	return chips
end

---@param details PullRequestDetails
---@param _opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(details, _opts, on_done)
	return pullrequests.subscription(details, function(subscribed, err)
		if not err then
			details.is_subscribed = subscribed
		end
		on_done()
	end)
end

---@return PullsPRPanelTab[]
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
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
			keymaps = require("atlas.pulls.providers.gitea.ui.overview_keymaps"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = review_icon,
			icon_hl = review_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = commit_icon,
			icon_hl = commit_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.commits"),
		},
	}
end

return M
