---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local icons = require("atlas.ui.shared.icons")

local state = {
	labels_by_name = nil, ---@type table<string, { color: string|nil, text_color: string|nil }>|nil
}

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderRow[]
function M.header_rows(_pr, details, loading)
	if details == nil then
		return loading and { header.loading_assignee_row() } or {}
	end

	local logins = {}
	for _, assignee in ipairs(details.assignees or {}) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_row(logins) }
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
	local by_name = state.labels_by_name or {}
	local shown = 0
	for _, label in ipairs(labels) do
		local name = label.name
		if name ~= "" then
			if shown >= MAX_LABELS then
				break
			end
			local meta = by_name[name] or {}
			local bg = type(meta.color) == "string" and meta.color:gsub("^#", "") or nil
			local fg = type(meta.text_color) == "string" and meta.text_color:gsub("^#", "") or nil
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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(pr, opts, on_done)
	local force = opts and opts.force_refresh == true
	local project_path = pr.repo_full_name
	if project_path == "" then
		state.labels_by_name = {}
		on_done()
		return nil
	end

	return pullrequests_api.fetch_project_labels(project_path, { force_refresh = force }, function(by_name, _)
		state.labels_by_name = by_name or {}
		on_done()
	end)
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
