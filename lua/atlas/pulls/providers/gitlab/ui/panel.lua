---@class GitLabPullsProviderPanel : PullsProviderPanel
local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")
local spinner = require("atlas.ui.components.spinner")
local icons = require("atlas.ui.shared.icons")

local state = {
	labels_by_name = nil, ---@type table<string, { color: string|nil, text_color: string|nil }>|nil
	header_loading = false,
}

local function reset_state()
	state.labels_by_name = nil
	state.header_loading = false
end

---@type { cancel: fun() }[]
local panel_in_flight = {}

local function cancel_panel_fetches()
	for _, handle in ipairs(panel_in_flight) do
		handle.cancel()
	end
	panel_in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track_panel(handle)
	if handle then
		table.insert(panel_in_flight, handle)
	end
end

---@param pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(pr)
	local raw = pr._raw or {}
	local assignees = type(raw.assignees) == "table" and raw.assignees or {}

	local logins = {}
	for _, node in ipairs(assignees) do
		local login = type(node) == "table" and tostring(node.username or node.name or "") or ""
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	local v1, v1_hl
	if #logins == 0 then
		v1 = "Unassigned"
		v1_hl = "AtlasTextMuted"
	else
		local parts = {}
		for _, login in ipairs(logins) do
			table.insert(parts, "@" .. login)
		end
		v1 = table.concat(parts, ", ")

		local spans = {}
		local cursor = 0
		for i, login in ipairs(logins) do
			local token = "@" .. login
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #token,
				hl_group = helper.author_hl(login),
			})
			cursor = cursor + #token
			if i < #logins then
				local sep = ", "
				table.insert(spans, {
					start_col = cursor,
					end_col = cursor + #sep,
					hl_group = "AtlasTextMuted",
				})
				cursor = cursor + #sep
			end
		end
		v1_hl = spans
	end

	return {
		{
			k1 = "Assignees:",
			v1 = v1,
			v1_hl = v1_hl,
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		},
	}
end

---@param pr PullRequest
---@return PullsPanelChip[]
function M.chips(pr)
	local chips = {}
	if state.header_loading and state.labels_by_name == nil then
		table.insert(chips, { label = spinner.with_text("Loading labels"), hl = "AtlasTextMuted" })
		return chips
	end

	local MAX_LABELS = 10
	local raw = type(pr._raw) == "table" and pr._raw or {}
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
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.fetches(pr, refresh, opts)
	cancel_panel_fetches()
	reset_state()

	local force = opts and opts.force_refresh == true
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local project_path = tostring(raw.project_path or pr.repo_full_name or "")

	if project_path ~= "" then
		state.header_loading = true
		track_panel(mr_api.get_project_labels(project_path, { force_refresh = force }, function(by_name, _)
			state.header_loading = false
			state.labels_by_name = by_name or {}
			refresh()
		end))
	end

	track_panel(mr_api.get_mr(pr, { force_refresh = force }, function(fresh, err)
		if not err and type(fresh) == "table" then
			pr.is_subscribed = fresh.is_subscribed
			pr._raw = fresh._raw
		end
		refresh()
	end))

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local checks = require("atlas.pulls.providers.gitlab.api.checks")
	overview_state.builds = "loading"
	track_panel(checks.get_builds(pr, { force_refresh = force }, function(builds, err)
		overview_state.builds = err and err or (builds or {})
		refresh()
	end))

end

---@param _pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(_pr, active_tab)
	if state.header_loading then
		return true
	end
	if active_tab == "conversation" then
		local conversation_state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
		return conversation_state.any_loading()
	end
	if active_tab == "review" then
		local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
		return comments_state.any_loading()
	end
	if active_tab == "commits" then
		local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
		return commits_state.any_loading()
	end
	if active_tab ~= nil and active_tab ~= "overview" then
		return false
	end

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	return overview_state.any_loading()
end

---@return PullsPanelTab[]
function M.tabs()
	return {
		{
			key = "overview",
			label = "Overview",
			icon = icons.general("overview"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("conversation"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = icons.pulls("review"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = icons.pulls("commit"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.commits"),
		},
		{
			key = "files",
			label = "Changes",
			icon = icons.pulls("changes"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.files"),
		},
	}
end

return M
