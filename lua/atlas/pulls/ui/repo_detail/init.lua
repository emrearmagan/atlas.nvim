local M = {}

local shared_detail = require("atlas.ui.detail")
local detail_state = require("atlas.pulls.ui.repo_detail.state")
local renderer = require("atlas.pulls.ui.repo_detail.renderer")
local detail_keymaps = require("atlas.pulls.ui.repo_detail.keymaps")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")

local overview_icon, overview_icon_hl = icons.general("overview")
local branch_icon, branch_icon_hl = icons.pulls("branch")
local tag_icon, tag_icon_hl = icons.pulls("tag")

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = overview_icon,
		icon_hl = overview_icon_hl,
		mod = require("atlas.pulls.ui.repo_detail.tabs.overview"),
	},
	{
		key = "branches",
		label = "Branches",
		icon = branch_icon,
		icon_hl = branch_icon_hl,
		mod = require("atlas.pulls.ui.repo_detail.tabs.branches"),
	},
	{
		key = "tags",
		label = "Tags",
		icon = tag_icon,
		icon_hl = tag_icon_hl,
		mod = require("atlas.pulls.ui.repo_detail.tabs.tags"),
	},
}

local SPINNER_INTERVAL_MS = 100
local spinner_timer = nil
local requests = request_scope.new()

local function stop_spinner()
	if spinner_timer ~= nil then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

---@return PullsRepoDetailTab[]
local function get_tabs()
	local provider = detail_state.provider
	local detail = provider and provider.capabilities.ui and provider.capabilities.ui.repo_detail
	local tabs = detail and detail.tabs and detail.tabs()
	return tabs and #tabs > 0 and tabs or DEFAULT_TABS
end

---@param tab_key string
---@return PullsRepoDetailTabModule|nil
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

---@return boolean
local function is_tab_loading()
	local tab_mod = get_tab_module(detail_state.current_tab)
	if tab_mod and tab_mod.is_loading then
		return tab_mod.is_loading()
	end
	return false
end

---@return boolean
local function is_any_loading()
	return detail_state.current_repo_details == "loading" or is_tab_loading()
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
			if not shared_detail.is_showing("repo") or not is_any_loading() then
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

local function cancel_requests()
	requests.cancel()
	requests = request_scope.new()
end

local function refresh()
	update_spinner()
	if shared_detail.is_showing("repo") then
		M.render()
	end
end

local function activate_current_tab()
	local tab_mod = get_tab_module(detail_state.current_tab)
	if tab_mod and tab_mod.activate then
		local buf = detail_state.buf
		if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
			tab_mod.activate(buf, refresh)
		end
	end
end

---@param old_key string|nil
---@param new_key string|nil
local function switch_tab_keymaps(old_key, new_key)
	local buf = detail_state.buf
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
			new_mod.activate(buf, refresh)
		end
	end
end

---@param repo PullsRepo
---@param opts { force_refresh: boolean|nil }|nil
local function load_tab(repo, opts)
	local tab_mod = get_tab_module(detail_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(repo, refresh, opts)
	end
end

local function cleanup()
	local buf = detail_state.buf
	switch_tab_keymaps(detail_state.current_tab, nil)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		detail_keymaps.remove(buf)
	end
	cancel_requests()
	stop_spinner()
	reset_tabs()
	detail_state.reset()
end

function M.is_open()
	return shared_detail.is_showing("repo", vim.api.nvim_get_current_tabpage())
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(lnum, entry)
	local tab_mod = get_tab_module(detail_state.current_tab)
	return tab_mod == nil or tab_mod.is_selectable_line == nil or tab_mod.is_selectable_line(lnum, entry)
end

---@param entry table
---@return boolean
function M.open_entry(entry)
	local details = detail_state.current_repo_details
	local repo = type(details) == "table" and details or detail_state.current_repo
	local tab_mod = get_tab_module(detail_state.current_tab)
	return repo ~= nil and tab_mod ~= nil and tab_mod.on_enter ~= nil and tab_mod.on_enter(repo, entry) == true
end

---@param repo PullsRepo
---@param opts { provider: PullsProvider|nil }|nil
function M.open(repo, opts)
	opts = opts or {}
	local provider = opts.provider or detail_state.provider
	if provider == nil then
		notify.error("Repository provider unavailable")
		return
	end

	local previous_provider = detail_state.provider
	if previous_provider and previous_provider ~= provider then
		cleanup()
	end
	detail_state.win, detail_state.buf = shared_detail.open("repo", cleanup, M.render)
	detail_state.provider = provider

	M.select(repo)
end

function M.refresh()
	if detail_state.current_repo then
		M.select(detail_state.current_repo, { force_refresh = true })
	end
end

---@param repo PullsRepo|nil
---@param opts { force_refresh: boolean|nil }|nil
function M.select(repo, opts)
	opts = opts or {}
	local provider = detail_state.provider
	local repository = provider and provider.capabilities.repository
	local same_repo = repo ~= nil
		and detail_state.current_repo ~= nil
		and tostring(detail_state.current_repo.id) == tostring(repo.id)
	if repo then
		if not same_repo then
			detail_state.current_repo_details = nil
		end
		detail_state.current_repo = repo
	end
	if detail_state.current_repo == nil then
		return
	end
	if detail_state.current_tab == nil then
		detail_state.current_tab = get_tabs()[1].key
	end

	local buf = detail_state.buf
	if buf then
		detail_keymaps.register(buf)
	end
	activate_current_tab()

	local should_fetch = opts.force_refresh == true or type(detail_state.current_repo_details) ~= "table"
	local fetching_details = repository ~= nil and repository.fetch_details ~= nil and should_fetch
	if fetching_details then
		local repo_key = tostring(detail_state.current_repo.id or "")
		cancel_requests()
		detail_state.current_repo_details = "loading"
		update_spinner()
		requests.run(function(done)
			return repository.fetch_details(detail_state.current_repo, {
				force_load = opts.force_refresh == true,
			}, done)
		end, function(details, err)
			if detail_state.current_repo == nil or tostring(detail_state.current_repo.id or "") ~= repo_key then
				return
			end
			if err == nil and details ~= nil then
				detail_state.current_repo_details = details
			else
				detail_state.current_repo_details = tostring(err or "Unknown error")
				notify.error("Failed to load repository: " .. tostring(err or "Unknown error"))
			end
			update_spinner()
			load_tab(detail_state.current_repo, opts)
			if shared_detail.is_showing("repo") then
				M.render()
			end
		end)
	end
	update_spinner()

	if not fetching_details then
		load_tab(detail_state.current_repo, opts)
	end
	if shared_detail.is_showing("repo") then
		M.render()
	end
end

---@param step 1|-1
local function change_tab(step)
	local tabs = get_tabs()
	local old_key = detail_state.current_tab
	local idx = 1
	for i, tab in ipairs(tabs) do
		if tab.key == old_key then
			idx = i
			break
		end
	end
	detail_state.current_tab = tabs[(idx - 1 + step) % #tabs + 1].key
	switch_tab_keymaps(old_key, detail_state.current_tab)
	if detail_state.current_repo ~= nil then
		load_tab(detail_state.current_repo, nil)
	end
	M.render()
end

function M.next_tab()
	change_tab(1)
end

function M.prev_tab()
	change_tab(-1)
end

function M.close()
	if shared_detail.is_showing("repo") then
		shared_detail.close()
	end
end

return M
