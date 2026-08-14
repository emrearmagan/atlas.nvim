local M = {}

local layout = require("atlas.ui.layout")
local root_panel_state = require("atlas.pulls.ui.panel.state")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local renderer = require("atlas.pulls.ui.panel.pr.renderer")
local icons = require("atlas.ui.shared.icons")
local overview_icon, overview_icon_hl = icons.general("overview")

local SPINNER_INTERVAL_MS = 100

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = overview_icon,
		icon_hl = overview_icon_hl,
		mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
	},
}

---@return PullsPanelTab[]
local function get_tabs()
	local state = require("atlas.pulls.state")
	local provider = state.provider
	local panel = provider and provider.capabilities.ui and provider.capabilities.ui.panel
	if panel and panel.tabs then
		local tabs = panel.tabs()
		if type(tabs) == "table" and #tabs > 0 then
			return tabs
		end
	end
	return DEFAULT_TABS
end

---@param tab_key string
---@return PullsPanelTab|nil
local function get_tab(tab_key)
	for _, tab in ipairs(get_tabs()) do
		if tab.key == tab_key then
			return tab
		end
	end
	return nil
end

---@param tab_key string
---@return PullsPanelTabModule|nil
local function get_tab_module(tab_key)
	local tab = get_tab(tab_key)
	return tab and tab.mod or nil
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

local function stop_spinner()
	if spinner_timer ~= nil then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

local function is_loading()
	if panel_state.current_pr == nil then
		return false
	end
	if panel_state.header_loading or panel_state.diffstat == "loading" or panel_state.pipelines == "loading" then
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

local function activate_current_tab()
	local buf = layout.buf_id("detail")
	local tab = get_tab(panel_state.current_tab)
	if tab == nil then
		return
	end
	if tab.mod.activate then
		tab.mod.activate(buf, refresh_panel)
	end
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) and tab.keymaps then
		tab.keymaps.register(buf)
	end
end

---@param old_key string|nil
---@param new_key string|nil
local function switch_tab_keymaps(old_key, new_key)
	local buf = layout.buf_id("detail")
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	if old_key and old_key ~= new_key then
		local old_tab = get_tab(old_key)
		if old_tab then
			if old_tab.keymaps then
				old_tab.keymaps.remove(buf)
			end
			if old_tab.mod.deactivate then
				old_tab.mod.deactivate(buf)
			end
		end
		require("atlas.pulls.ui.panel.pr.keymaps").register(buf)
	end

	if new_key and old_key ~= new_key then
		local new_tab = get_tab(new_key)
		if new_tab then
			if new_tab.mod.activate then
				new_tab.mod.activate(buf, refresh_panel)
			end
			if new_tab.keymaps then
				new_tab.keymaps.register(buf)
			end
		end
	end
end

---@param pr PullRequest|nil
---@return boolean
local function is_current_pr(pr)
	local current = panel_state.current_pr
	return current ~= nil
		and tostring(current.id or "") == tostring(pr and pr.id or "")
		and tostring(current.repo_full_name or "") == tostring(pr and pr.repo_full_name or "")
end

---@param pr PullRequest|nil
---@return fun()
local function make_refresh_callback(pr)
	return function()
		if not is_current_pr(pr) then
			return
		end
		update_spinner()
		if M.is_open() then
			M.render()
		end
	end
end

---@type { cancel: fun() }[]
local panel_requests = {}

local function cancel_panel_requests()
	for _, request in ipairs(panel_requests) do
		request.cancel()
	end
	panel_requests = {}
end

---@param request { cancel: fun() }|nil
local function track_panel_request(request)
	if request then
		table.insert(panel_requests, request)
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
local function fetch_panel_data(pr, opts)
	cancel_panel_requests()

	local state = require("atlas.pulls.state")
	local provider = state.provider
	if provider == nil then
		return
	end

	local refresh = make_refresh_callback(pr)
	local panel = provider and provider.capabilities.ui and provider.capabilities.ui.panel
	if panel and panel.fetch_header then
		panel_state.header_loading = true
		track_panel_request(panel.fetch_header(pr, opts, function()
			if not is_current_pr(pr) then
				return
			end
			panel_state.header_loading = false
			refresh()
		end))
	else
		panel_state.header_loading = false
	end

	local force_refresh = opts and opts.force_refresh == true
	local core = provider.capabilities.core
	if core.fetch_diffstat then
		panel_state.diffstat = "loading"
		track_panel_request(core.fetch_diffstat(pr, { force_refresh = force_refresh }, function(entries, err)
			if not is_current_pr(pr) then
				return
			end
			panel_state.diffstat = err and err or (entries or {})
			refresh()
		end))
	end

	local pipelines = provider.capabilities.pipelines
	if pipelines then
		panel_state.pipelines = "loading"
		track_panel_request(pipelines.fetch(pr, { force_refresh = force_refresh }, function(items, err)
			if not is_current_pr(pr) then
				return
			end
			panel_state.pipelines = err and err or (items or {})
			refresh()
		end))
	end
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil }|nil
local function load_active_tab(pr, repo, opts)
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(pr, repo, make_refresh_callback(pr), opts)
	end
end

-- Public API

---@return boolean
function M.is_open()
	return root_panel_state.current_panel == "pr" and layout.win_id("detail") ~= nil
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param pr PullRequest|nil
---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
function M.on_select(pr, repo, opts)
	opts = opts or {}

	local same_pr = pr ~= nil
		and panel_state.current_pr ~= nil
		and tostring(panel_state.current_pr.id) == tostring(pr.id)
		and tostring(panel_state.current_pr.repo_full_name) == tostring(pr.repo_full_name)
	local same_repo = repo ~= nil
		and panel_state.current_repo ~= nil
		and tostring(panel_state.current_repo.id or panel_state.current_repo.name or "")
			== tostring(repo.id or repo.name or "")
	local context_changed = (pr ~= nil and not same_pr) or (repo ~= nil and not same_repo)

	panel_state.current_pr = pr
	panel_state.current_repo = repo
	if panel_state.current_pr == nil then
		return
	end

	activate_current_tab()

	local should_fetch = context_changed or opts.force_refresh == true

	if not same_pr and pr ~= nil then
		local old_key = panel_state.current_tab
		if panel_state.current_tab == nil then
			panel_state.current_tab = get_tabs()[1].key
		end
		switch_tab_keymaps(old_key, panel_state.current_tab)
		stop_spinner()
	end

	if context_changed or opts.force_refresh == true then
		reset_tabs()
		panel_state.diffstat = nil
		panel_state.pipelines = nil
		panel_state.header_loading = false
	end

	if should_fetch then
		fetch_panel_data(panel_state.current_pr, opts)
		load_active_tab(
			panel_state.current_pr,
			panel_state.current_repo,
			{ force_refresh = opts.force_refresh == true }
		)
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

	local next_idx = idx + 1
	if next_idx > #tabs then
		next_idx = 1
	end

	panel_state.current_tab = tabs[next_idx].key
	switch_tab_keymaps(old_key, panel_state.current_tab)

	if panel_state.current_pr then
		load_active_tab(panel_state.current_pr, panel_state.current_repo)
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

	if panel_state.current_pr then
		load_active_tab(panel_state.current_pr, panel_state.current_repo)
		update_spinner()
	end

	M.render()
	scroll_to_top()
end

function M.close()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_spinner()
	cancel_panel_requests()
	reset_tabs()
	panel_state.reset()
end

function M.activate()
	update_spinner()
end

function M.deactivate()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_spinner()
end

return M
