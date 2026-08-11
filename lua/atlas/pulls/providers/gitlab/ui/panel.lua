---@class GitLabPullsProviderPanel : PullsProviderPanel
local M = {}

local header = require("atlas.pulls.ui.panel.components.header")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local spinner = require("atlas.ui.components.spinner")
local icons = require("atlas.ui.shared.icons")

local state = {
	labels_by_name = nil, ---@type table<string, { color: string|nil, text_color: string|nil }>|nil
}

local function reset_state()
	state.labels_by_name = nil
end

---@param pr PullRequest
---@param _loading boolean
---@return PullsPanelHeaderRow[]
function M.header_rows(pr, _loading)
	local raw = pr._raw
	local assignees = type(raw.assignees) == "table" and raw.assignees or {}

	local logins = {}
	for _, node in ipairs(assignees) do
		local login = type(node) == "table" and tostring(node.username or node.name or "") or ""
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
	if loading and state.labels_by_name == nil then
		table.insert(chips, { label = spinner.with_text("Loading labels"), hl = "AtlasTextMuted" })
		return chips
	end

	local MAX_LABELS = 10
	local raw = pr._raw
	local labels = type(raw.labels) == "table" and raw.labels or {}
	local by_name = state.labels_by_name or {}
	local shown = 0
	for _, entry in ipairs(labels) do
		local name = type(entry) == "string" and entry or (type(entry) == "table" and entry.name) or nil
		if type(name) == "string" and name ~= "" then
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
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(pr, opts, on_done)
	reset_state()

	local force = opts and opts.force_refresh == true
	local project_path = pr.repo_full_name
	local fetch_labels = project_path ~= ""
	local fetch_details = not (opts and opts.pr_refreshed)
	local pending = (fetch_labels and 1 or 0) + (fetch_details and 1 or 0)
	local requests = {}

	if pending == 0 then
		on_done()
		return
	end

	local function complete()
		pending = pending - 1
		if pending == 0 then
			on_done()
		end
	end

	if fetch_labels then
		local request = pullrequests_api.fetch_project_labels(
			project_path,
			{ force_refresh = force },
			function(by_name, _)
				state.labels_by_name = by_name or {}
				complete()
			end
		)
		if request then
			table.insert(requests, request)
		end
	end

	if fetch_details then
		local request = pullrequests_api.fetch_pullrequest(pr, { force_refresh = force }, function(fresh, err)
			if not err and type(fresh) == "table" then
				pr.is_subscribed = fresh.is_subscribed
				pr._raw = fresh._raw
			end
			complete()
		end)
		if request then
			table.insert(requests, request)
		end
	end

	return {
		cancel = function()
			for _, request in ipairs(requests) do
				request.cancel()
			end
		end,
	}
end

---@return PullsPanelTab[]
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
