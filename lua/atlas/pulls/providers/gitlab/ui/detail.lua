---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local icons = require("atlas.ui.shared.icons")

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
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_field(logins) }
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, loading)
	if details == nil or loading then
		return {}
	end

	local chips = {}
	local MAX_LABELS = 10
	local labels = details.labels or {}
	local shown = 0
	for _, label in ipairs(labels) do
		---@cast label GitLabPullsLabel
		local name = label.name
		if name ~= "" then
			if shown >= MAX_LABELS then
				break
			end
			local bg = type(label.color) == "string" and label.color:gsub("^#", "") or nil
			local fg = type(label.text_color) == "string" and label.text_color:gsub("^#", "") or nil
			local hl = "AtlasTabInactive"
			if type(bg) == "string" and bg:match("^%x%x%x%x%x%x$") then
				hl = "AtlasGLLabel_" .. bg
				local opts = { bg = "#" .. bg, bold = true }
				if type(fg) == "string" and fg:match("^%x%x%x%x%x%x$") then
					opts.fg = "#" .. fg
				else
					opts.fg = "#1e1e2e"
				end
				vim.api.nvim_set_hl(0, hl, opts)
			end
			table.insert(chips, { label = name, hl = hl })
			shown = shown + 1
		end
	end
	local remaining = #labels - shown
	if remaining > 0 then
		table.insert(chips, { label = string.format("+%d more", remaining), hl = "AtlasTextMuted" })
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
