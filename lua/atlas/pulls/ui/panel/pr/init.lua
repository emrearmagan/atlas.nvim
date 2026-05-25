local M = {}

local layout = require("atlas.ui.layout")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local renderer = require("atlas.pulls.ui.panel.pr.renderer")
local icons = require("atlas.ui.shared.icons")

local SPINNER_INTERVAL_MS = 100

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = icons.general("overview"),
		mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
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
	local pr = panel_state.current_pr
	if pr == nil then
		return false
	end
	local state = require("atlas.pulls.state")
	local provider = state.provider
	if provider and provider.panel and type(provider.panel.is_loading) == "function" then
		return provider.panel.is_loading(pr, panel_state.current_tab)
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

---@return PullsPanelTab[]
local function get_tabs()
	local state = require("atlas.pulls.state")
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
	if tab.mod and type(tab.mod.activate) == "function" then
		tab.mod.activate(buf, refresh_panel)
	end
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) and tab.keymaps and type(tab.keymaps.register) == "function" then
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
			if old_tab.keymaps and type(old_tab.keymaps.remove) == "function" then
				old_tab.keymaps.remove(buf)
			end
			if old_tab.mod and type(old_tab.mod.deactivate) == "function" then
				old_tab.mod.deactivate(buf)
			end
		end
	end

	if new_key and old_key ~= new_key then
		local new_tab = get_tab(new_key)
		if new_tab then
			if new_tab.mod and type(new_tab.mod.activate) == "function" then
				new_tab.mod.activate(buf, refresh_panel)
			end
			if new_tab.keymaps and type(new_tab.keymaps.register) == "function" then
				new_tab.keymaps.register(buf)
			end
		end
	end
end

---@param pr PullRequest|nil
---@return fun()
local function make_refresh_callback(pr)
	local expected_id = tostring(pr and pr.id or "")
	local expected_repo = tostring(pr and pr.repo_full_name or "")
	return function()
		local active = panel_state.current_pr
		if active == nil then
			return
		end
		if tostring(active.id or "") ~= expected_id or tostring(active.repo_full_name or "") ~= expected_repo then
			return
		end
		update_spinner()
		if M.is_open() then
			M.render()
		end
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
local function dispatch_provider_fetches(pr, opts)
	local state = require("atlas.pulls.state")
	local provider = state.provider
	if provider and provider.panel and type(provider.panel.fetches) == "function" then
		provider.panel.fetches(pr, make_refresh_callback(pr), opts)
	end
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil }|nil
local function notify_tab(pr, repo, opts)
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and type(tab_mod.on_select) == "function" then
		tab_mod.on_select(pr, repo, make_refresh_callback(pr), opts)
	end
end

local function reset_pr_tab_data()
	local function reset_state(mod_path)
		local ok, mod = pcall(require, mod_path)
		if ok and type(mod) == "table" and type(mod.reset) == "function" then
			mod.reset()
		end
	end

	reset_state("atlas.pulls.ui.panel.pr.tabs.overview.state")
	reset_state("atlas.pulls.ui.panel.pr.tabs.activity.state")
	reset_state("atlas.pulls.ui.panel.pr.tabs.commits.state")
	reset_state("atlas.pulls.ui.panel.pr.tabs.files.state")
	reset_state("atlas.pulls.ui.panel.pr.tabs.review.state")
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

---@param pr PullRequest|nil
---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil }|nil
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
		reset_pr_tab_data()
	end

	if should_fetch then
		dispatch_provider_fetches(panel_state.current_pr, { force_refresh = opts.force_refresh == true })
		notify_tab(panel_state.current_pr, panel_state.current_repo, { force_refresh = opts.force_refresh == true })
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
		notify_tab(panel_state.current_pr, panel_state.current_repo)
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
		notify_tab(panel_state.current_pr, panel_state.current_repo)
		update_spinner()
	end

	M.render()
	scroll_to_top()
end

function M.close()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_spinner()
	panel_state.reset()
end

function M.activate() end

function M.deactivate()
	local buf = layout.buf_id("detail")
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and type(tab_mod.deactivate) == "function" then
		tab_mod.deactivate(buf)
	end
end

return M
