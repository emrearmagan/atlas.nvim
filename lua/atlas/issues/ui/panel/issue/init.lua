local M = {}

local layout = require("atlas.ui.layout")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local renderer = require("atlas.issues.ui.panel.issue.renderer")

local SPINNER_INTERVAL_MS = 100

---@return IssuesPanelTab[]
local function get_tabs()
	local state = require("atlas.issues.state")
	local provider = state.provider
	local panel = provider and provider.capabilities.ui and provider.capabilities.ui.panel
	if panel and panel.tabs then
		local tabs = panel.tabs()
		if type(tabs) == "table" then
			return tabs
		end
	end
	return {}
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

local function reset_tabs()
	for _, tab in ipairs(get_tabs()) do
		if tab.mod.reset then
			tab.mod.reset()
		end
	end
end

-- Loading spinner

local spinner_timer = nil
---@type { cancel: fun() }|nil
local header_request = nil

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
	if panel_state.header_loading then
		return true
	end
	local tab = get_tab_module(panel_state.current_tab)
	return tab ~= nil and tab.is_loading ~= nil and tab.is_loading()
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

-- Helper

local function refresh_panel()
	if M.is_open() then
		M.render()
	end
end

local function scroll_to_top()
	local win = layout.win_id("detail")
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
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
		if old_mod and old_mod.deactivate and old_key ~= new_key then
			old_mod.deactivate(buf)
		end
	end

	if new_key then
		local new_mod = get_tab_module(new_key)
		if new_mod and new_mod.activate and old_key ~= new_key then
			new_mod.activate(buf, refresh_panel)
		end
	end
end

---@param issue Issue|nil
---@return boolean
local function is_current_issue(issue)
	local current = panel_state.current_issue
	return current ~= nil and tostring(current.key or "") == tostring(issue and issue.key or "")
end

---@param issue Issue|nil
---@return fun()
local function make_refresh_callback(issue)
	return function()
		if not is_current_issue(issue) then
			return
		end
		update_spinner()
		if M.is_open() then
			M.render()
		end
	end
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil, issue_refreshed: boolean|nil }|nil
local function fetch_header(issue, opts)
	if header_request then
		header_request.cancel()
		header_request = nil
	end

	local state = require("atlas.issues.state")
	local provider = state.provider
	local panel = provider and provider.capabilities.ui and provider.capabilities.ui.panel
	if panel and panel.fetch_header then
		local refresh = make_refresh_callback(issue)
		panel_state.header_loading = true
		header_request = panel.fetch_header(issue, opts, function()
			if not is_current_issue(issue) then
				return
			end
			panel_state.header_loading = false
			refresh()
		end)
	else
		panel_state.header_loading = false
	end
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
local function load_active_tab(issue, opts)
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(issue, make_refresh_callback(issue), opts)
	end
end

-- Public API

---@return boolean
function M.is_open()
	return layout.win_id("detail") ~= nil
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param issue Issue|nil
---@param opts { force_refresh: boolean|nil, issue_refreshed: boolean|nil }|nil
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
		local tabs = get_tabs()
		local valid = false
		for _, t in ipairs(tabs) do
			if t.key == panel_state.current_tab then
				valid = true
				break
			end
		end
		if not valid then
			panel_state.current_tab = tabs[1] and tabs[1].key or nil
		end
		switch_tab_keymaps(old_key, panel_state.current_tab)
		stop_spinner()
	else
		switch_tab_keymaps(nil, panel_state.current_tab)
	end

	if context_changed or opts.force_refresh == true then
		reset_tabs()
	end

	if should_fetch then
		fetch_header(panel_state.current_issue, opts)
		load_active_tab(panel_state.current_issue, { force_refresh = opts.force_refresh == true })
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
		load_active_tab(panel_state.current_issue)
		update_spinner()
	end

	M.render()
	scroll_to_top()
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
		load_active_tab(panel_state.current_issue)
		update_spinner()
	end

	M.render()
end

function M.close()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_spinner()
	if header_request then
		header_request.cancel()
		header_request = nil
	end
	reset_tabs()
	panel_state.reset()
end

return M
