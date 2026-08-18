---@class GitHubProviderPRPanel : PullsProviderPRPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.panel.components.header")
local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
local spinner = require("atlas.ui.components.spinner")

local MAX_HASH_LEN = 12

---@param hex string
---@return string
local function label_hl(hex)
	local name = string.format("AtlasGHLabel_%s", hex)
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

-- Panel

---@param pr PullRequest
---@param loading boolean
---@return PullsPanelHeaderRow[]
function M.header_rows(pr, loading)
	if loading and pr.assignees == nil then
		return {
			{
				k1 = "Assignees:",
				v1 = spinner.with_text("Loading..."),
				v1_hl = "AtlasTextMuted",
				k2 = "",
				v2 = "",
				v2_hl = "AtlasTextMuted",
			},
		}
	end

	local logins = {}
	for _, assignee in ipairs(pr.assignees or {}) do
		local login = assignee.username
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_row(logins) }
end

---@param pr PullRequest
---@param loading boolean
---@return PullsPanelChip[]
function M.chips(pr, loading)
	local chips = {}

	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	if loading and pr.labels == nil then
		table.insert(chips, { label = spinner.with_text("Loading labels"), hl = "AtlasTextMuted" })
	else
		for _, lbl in ipairs(pr.labels or {}) do
			local name = tostring(lbl.name or "")
			if name ~= "" then
				local color = tostring(lbl.color or "")
				local hl = color ~= "" and label_hl(color) or "AtlasTabInactive"
				table.insert(chips, { label = name, hl = hl })
			end
		end
	end

	return chips
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(pr, opts, on_done)
	local owner = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")
	local force = opts and opts.force_refresh == true

	if opts and opts.pr_refreshed then
		on_done()
	elseif owner ~= "" and repo ~= "" and pr.id ~= nil then
		return pullrequests.get_pr(owner, repo, pr.id, function(fresh, err)
			if not err and type(fresh) == "table" then
				pr.is_subscribed = fresh.is_subscribed
				pr.assignees = fresh.assignees
				pr.reviewers = fresh.reviewers
				pr.labels = fresh.labels
				pr.lines_added = fresh.lines_added
				pr.lines_removed = fresh.lines_removed
				pr._raw = fresh._raw
			end
			on_done()
		end, { force_load = force })
	else
		on_done()
	end
end

-- Tabs

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
			keymaps = require("atlas.pulls.providers.github.ui.overview_keymaps"),
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
