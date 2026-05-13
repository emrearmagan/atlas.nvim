local M = {}

local layout = require("atlas.ui.layout")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local renderer = require("atlas.issues.ui.panel.issue.renderer")
local icons = require("atlas.ui.shared.icons")

local SPINNER_INTERVAL_MS = 100

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = icons.general("overview"),
		mod = require("atlas.issues.ui.panel.issue.tabs.overview"),
	},
	{
		key = "comments",
		label = "Comments",
		icon = icons.general("comment"),
		mod = require("atlas.issues.ui.panel.issue.tabs.comments"),
	},
	{
		key = "activity",
		label = "Activity",
		icon = icons.pulls("activity"),
		mod = require("atlas.issues.ui.panel.issue.tabs.activity"),
	},
}

--------------------------------------------------------------------------------
-- Loading spinner
--------------------------------------------------------------------------------

local spinner_timer = nil

local function stop_spinner()
	if spinner_timer ~= nil then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

local function is_loading()
	local issue = panel_state.current_issue
	if issue == nil then
		return false
	end
	local state = require("atlas.issues.state")
	local provider = state.provider
	if provider and provider.panel and type(provider.panel.is_loading) == "function" then
		return provider.panel.is_loading(issue)
	end
	return false
end

local function start_spinner()
	if spinner_timer ~= nil then
		return
	end
	spinner_timer = vim.loop.new_timer()
	if spinner_timer == nil then
		return
	end
	spinner_timer:start(
		SPINNER_INTERVAL_MS,
		SPINNER_INTERVAL_MS,
		vim.schedule_wrap(function()
			if not M.is_open() or not is_loading() then
				stop_spinner()
				return
			end
			M.render()
		end)
	)
end

local function update_spinner()
	if is_loading() then
		start_spinner()
	else
		stop_spinner()
	end
end

--------------------------------------------------------------------------------
-- Helper
--------------------------------------------------------------------------------

---@return IssuesPanelTab[]
local function get_tabs()
	local state = require("atlas.issues.state")
	local provider = state.provider
	if provider and provider.panel and provider.panel.tabs then
		local tabs = provider.panel.tabs()
		if type(tabs) == "table" and #tabs > 0 then
			return tabs
		end
	end
	return DEFAULT_TABS
end

---@param tab_key string
---@return IssuesPanelTabModule|nil
local function get_tab_module(tab_key)
	for _, tab in ipairs(get_tabs()) do
		if tab.key == tab_key then
			return tab.mod
		end
	end
	return nil
end

local function refresh_panel()
	if M.is_open() then
		M.render()
	end
end

---@param old_key string|nil
---@param new_key string|nil
local function switch_tab_keymaps(old_key, new_key)
	local buf = layout.buf_id("detail")
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	if old_key then
		local old_mod = get_tab_module(old_key)
		if old_mod and type(old_mod.deactivate) == "function" and old_key ~= new_key then
			old_mod.deactivate(buf)
		end
	end

	if new_key then
		local new_mod = get_tab_module(new_key)
		if new_mod and type(new_mod.activate) == "function" and old_key ~= new_key then
			new_mod.activate(buf, refresh_panel)
		end
	end
end

---@param issue Issue|nil
---@return fun()
local function make_refresh_callback(issue)
	local expected_key = tostring(issue and issue.key or "")
	return function()
		local active = panel_state.current_issue
		if active == nil or tostring(active.key or "") ~= expected_key then
			return
		end
		update_spinner()
		if M.is_open() then
			M.render()
		end
	end
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
local function dispatch_provider_fetches(issue, opts)
	local state = require("atlas.issues.state")
	local provider = state.provider
	if provider and provider.panel and type(provider.panel.fetches) == "function" then
		provider.panel.fetches(issue, make_refresh_callback(issue), { force_load = opts and opts.force_refresh == true })
	end
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
local function notify_tab(issue, opts)
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and type(tab_mod.on_select) == "function" then
		tab_mod.on_select(issue, make_refresh_callback(issue), opts)
	end
end

local function reset_tab_data()
	local function reset_state(mod_path)
		local ok, mod = pcall(require, mod_path)
		if ok and type(mod) == "table" and type(mod.reset) == "function" then
			mod.reset()
		end
	end

	reset_state("atlas.issues.ui.panel.issue.tabs.overview.state")
	reset_state("atlas.issues.ui.panel.issue.tabs.comments.state")
	reset_state("atlas.issues.ui.panel.issue.tabs.activity.state")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@return boolean
function M.is_open()
	return layout.win_id("detail") ~= nil
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param issue Issue|nil
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, opts)
	opts = opts or {}

	local same_issue = issue ~= nil
		and panel_state.current_issue ~= nil
		and tostring(panel_state.current_issue.key) == tostring(issue.key)
	local context_changed = issue ~= nil and not same_issue

	if issue ~= nil then
		panel_state.current_issue = issue
	end

	if panel_state.current_issue == nil then
		return
	end

	local should_fetch = context_changed or opts.force_refresh == true

	if not same_issue and issue ~= nil then
		local old_key = panel_state.current_tab
		if panel_state.current_tab == nil then
			panel_state.current_tab = get_tabs()[1].key
		end
		switch_tab_keymaps(old_key, panel_state.current_tab)
		stop_spinner()
	else
		switch_tab_keymaps(nil, panel_state.current_tab)
	end

	if context_changed then
		reset_tab_data()
	end

	if should_fetch then
		dispatch_provider_fetches(panel_state.current_issue, opts)
		notify_tab(panel_state.current_issue, { force_refresh = opts.force_refresh == true })
		update_spinner()
	end

	if M.is_open() then
		M.render()
	end
end

function M.next_tab()
	local tabs = get_tabs()
	local old_key = panel_state.current_tab
	local idx = 1
	for i, tab in ipairs(tabs) do
		if tab.key == old_key then
			idx = i
			break
		end
	end

	local next_idx = idx % #tabs + 1
	panel_state.current_tab = tabs[next_idx].key
	switch_tab_keymaps(old_key, panel_state.current_tab)

	if panel_state.current_issue then
		notify_tab(panel_state.current_issue)
		update_spinner()
	end

	M.render()
end

function M.prev_tab()
	local tabs = get_tabs()
	local old_key = panel_state.current_tab
	local idx = 1
	for i, tab in ipairs(tabs) do
		if tab.key == old_key then
			idx = i
			break
		end
	end

	local prev_idx = idx - 1
	if prev_idx < 1 then
		prev_idx = #tabs
	end

	panel_state.current_tab = tabs[prev_idx].key
	switch_tab_keymaps(old_key, panel_state.current_tab)

	if panel_state.current_issue then
		notify_tab(panel_state.current_issue)
		update_spinner()
	end

	M.render()
end

function M.close()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_spinner()
	panel_state.reset()
end

function M.activate() end

function M.deactivate()
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and type(tab_mod.deactivate) == "function" then
		tab_mod.deactivate()
	end
end

return M
