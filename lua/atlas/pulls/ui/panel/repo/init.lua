local M = {}

local layout = require("atlas.ui.layout")
local root_panel_state = require("atlas.pulls.ui.panel.state")
local panel_state = require("atlas.pulls.ui.panel.repo.state")
local renderer = require("atlas.pulls.ui.panel.repo.renderer")
local panel_keymaps = require("atlas.pulls.ui.panel.keymaps")
local icons = require("atlas.ui.shared.icons")
local statusline = require("atlas.ui.statusline")

local overview_icon, overview_icon_hl = icons.general("overview")
local branch_icon, branch_icon_hl = icons.pulls("branch")
local tag_icon, tag_icon_hl = icons.pulls("tag")

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = overview_icon,
		icon_hl = overview_icon_hl,
		mod = require("atlas.pulls.ui.panel.repo.tabs.overview"),
	},
	{
		key = "branches",
		label = "Branches",
		icon = branch_icon,
		icon_hl = branch_icon_hl,
		mod = require("atlas.pulls.ui.panel.repo.tabs.branches"),
	},
	{
		key = "tags",
		label = "Tags",
		icon = tag_icon,
		icon_hl = tag_icon_hl,
		mod = require("atlas.pulls.ui.panel.repo.tabs.tags"),
	},
}

local SPINNER_INTERVAL_MS = 100
local spinner_timer = nil
local detail_request = nil

local function stop_spinner()
	if spinner_timer ~= nil then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

---@return PullsRepoPanelTab[]
local function get_tabs()
	local state = require("atlas.pulls.state")
	local provider = state.provider
	local repo_panel = provider and provider.capabilities.ui and provider.capabilities.ui.repo_panel
	if repo_panel and repo_panel.tabs then
		local tabs = repo_panel.tabs()
		if type(tabs) == "table" and #tabs > 0 then
			return tabs
		end
	end
	return DEFAULT_TABS
end

---@param tab_key string
---@return PullsRepoPanelTabModule|nil
local function get_tab_module(tab_key)
	for _, tab in ipairs(get_tabs()) do
		if tab.key == tab_key then
			return tab.mod
		end
	end
	return nil
end

M.get_tab_module = get_tab_module

---@return boolean
local function is_tab_loading()
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.is_loading then
		return tab_mod.is_loading()
	end
	return false
end

---@return boolean
local function is_any_loading()
	return panel_state.current_repo_details == "loading" or is_tab_loading()
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
			if not M.is_open() or not is_any_loading() then
				stop_spinner()
				return
			end
			M.render()
		end)
	)
end

local function update_spinner()
	if is_any_loading() then
		start_spinner()
	else
		stop_spinner()
	end
end

local function stop_request()
	if detail_request ~= nil and type(detail_request.cancel) == "function" then
		detail_request.cancel()
	end
	detail_request = nil
end

local function refresh_panel()
	update_spinner()
	if M.is_open() then
		M.render()
	end
end

local function activate_current_tab()
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.activate then
		local buf = layout.buf_id("detail")
		if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
			tab_mod.activate(buf, refresh_panel)
		end
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

---@param repo PullsRepo
---@param opts { force_refresh: boolean|nil }|nil
local function notify_tab(repo, opts)
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(repo, refresh_panel, opts)
	end
end

function M.is_open()
	return root_panel_state.current_panel == "repo" and layout.win_id("detail") ~= nil
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(repo, opts)
	opts = opts or {}
	local state = require("atlas.pulls.state")
	local provider = state.provider
	local repository = provider and provider.capabilities.repository
	local same_repo = repo ~= nil
		and panel_state.current_repo ~= nil
		and tostring(panel_state.current_repo.id) == tostring(repo.id)
	if repo then
		if not same_repo then
			panel_state.current_repo_details = nil
		end
		panel_state.current_repo = repo
	end
	if panel_state.current_repo == nil then
		return
	end
	if panel_state.current_tab == nil then
		panel_state.current_tab = get_tabs()[1].key
	end

	local buf = layout.buf_id("detail")
	if buf then
		panel_keymaps.register(buf)
	end
	activate_current_tab()

	local should_fetch = opts.force_refresh == true or type(panel_state.current_repo_details) ~= "table"
	if repository and repository.fetch_details and should_fetch then
		local repo_key = tostring(panel_state.current_repo.id or "")
		stop_request()
		panel_state.current_repo_details = "loading"
		update_spinner()
		detail_request = repository.fetch_details(panel_state.current_repo, {
			force_load = opts.force_refresh == true,
		}, function(details, err)
			detail_request = nil
			if panel_state.current_repo == nil or tostring(panel_state.current_repo.id or "") ~= repo_key then
				return
			end
			if err == nil and details ~= nil then
				panel_state.current_repo_details = details
			else
				panel_state.current_repo_details = tostring(err or "Unknown error")
				statusline.notify("error", "Failed to load repository: " .. tostring(err or "Unknown error"))
			end
			update_spinner()
			notify_tab(panel_state.current_repo, opts)
			if M.is_open() then
				M.render()
			end
		end)
	end
	update_spinner()

	notify_tab(panel_state.current_repo, opts)
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
	if panel_state.current_repo ~= nil then
		notify_tab(panel_state.current_repo, nil)
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
	if panel_state.current_repo ~= nil then
		notify_tab(panel_state.current_repo, nil)
	end
	M.render()
end

function M.close()
	switch_tab_keymaps(panel_state.current_tab, nil)
	stop_request()
	stop_spinner()
	panel_state.reset()
end

function M.activate() end

function M.deactivate()
	stop_request()
	stop_spinner()

	local buf = layout.buf_id("detail")
	local tab_mod = get_tab_module(panel_state.current_tab)
	if tab_mod and tab_mod.deactivate then
		tab_mod.deactivate(buf)
	end
	panel_state.reset()
end

return M
