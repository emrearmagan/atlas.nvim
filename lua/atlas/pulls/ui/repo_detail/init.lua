local M = {}

local detail_ui = require("atlas.ui.detail")
local state = require("atlas.pulls.ui.repo_detail.state")
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
		icon = { icon = overview_icon, hl_group = overview_icon_hl },
		mod = require("atlas.pulls.ui.repo_detail.tabs.overview"),
	},
	{
		key = "branches",
		label = "Branches",
		icon = { icon = branch_icon, hl_group = branch_icon_hl },
		mod = require("atlas.pulls.ui.repo_detail.tabs.branches"),
	},
	{
		key = "tags",
		label = "Tags",
		icon = { icon = tag_icon, hl_group = tag_icon_hl },
		mod = require("atlas.pulls.ui.repo_detail.tabs.tags"),
	},
}

local SPINNER_INTERVAL_MS = 100
local function stop_spinner()
	if state.spinner_timer ~= nil then
		state.spinner_timer:stop()
		state.spinner_timer:close()
		state.spinner_timer = nil
	end
end

---@param tab_key string
---@return PullsRepoDetailTabModule|nil
local function tab_module(tab_key)
	for _, tab in ipairs(state.tabs) do
		if tab.key == tab_key then
			return tab.mod
		end
	end
	return nil
end

local function reset_tabs()
	for _, tab in ipairs(state.tabs) do
		if tab.mod.reset then
			tab.mod.reset()
		end
	end
end

local function render()
	renderer.render(state.tabs, tab_module)
end

---@return boolean
local function is_loading()
	if state.current_repo_details == "loading" then
		return true
	end
	local tab = tab_module(state.current_tab)
	return tab ~= nil and tab.is_loading ~= nil and tab.is_loading()
end

local function start_spinner()
	if state.spinner_timer ~= nil then
		return
	end
	state.spinner_timer = vim.loop.new_timer()
	if state.spinner_timer == nil then
		return
	end
	state.spinner_timer:start(
		SPINNER_INTERVAL_MS,
		SPINNER_INTERVAL_MS,
		vim.schedule_wrap(function()
			if not detail_ui.is_showing("repo") or not is_loading() then
				stop_spinner()
				return
			end
			render()
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

local function cancel_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

local function refresh()
	update_spinner()
	if detail_ui.is_showing("repo") then
		render()
	end
end

---@param tab_key string|nil
local function set_tab(tab_key)
	local old_key = state.current_tab
	if old_key == tab_key then
		return
	end

	local buf = state.buf
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		state.current_tab = tab_key
		return
	end
	if old_key then
		local old_mod = tab_module(old_key)
		if old_mod and old_mod.deactivate then
			old_mod.deactivate(buf)
		end
	end

	state.current_tab = tab_key
	if tab_key then
		local new_mod = tab_module(tab_key)
		if new_mod and new_mod.activate then
			new_mod.activate(buf, refresh)
		end
	end
end

---@param repo PullsRepo
---@param opts { force_refresh: boolean|nil }|nil
local function load_tab(repo, opts)
	local tab_mod = tab_module(state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(repo, refresh, opts)
	end
end

local function clear_repo()
	cancel_requests()
	stop_spinner()
	reset_tabs()
	state.current_repo = nil
	state.current_repo_details = nil
	state.line_map = {}
end

---@param provider PullsProvider
local function set_provider(provider)
	if state.provider == provider then
		return
	end

	set_tab(nil)
	clear_repo()
	state.provider = provider
	local detail = provider.capabilities.ui and provider.capabilities.ui.repo_detail
	local provider_tabs = detail and detail.tabs and detail.tabs()
	state.tabs = provider_tabs and #provider_tabs > 0 and provider_tabs or DEFAULT_TABS

	local first_tab = state.tabs[1]
	set_tab(first_tab and first_tab.key or nil)
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		detail_keymaps.register(state.buf)
	end
end

local function cleanup()
	local buf = state.buf
	set_tab(nil)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		detail_keymaps.remove(buf)
	end
	stop_spinner()
	reset_tabs()
	state.reset()
end

---@param repo PullsRepo
---@param force_refresh boolean
local function load_repo(repo, force_refresh)
	state.current_repo = repo
	local repository = state.provider and state.provider.capabilities.repository
	if repository == nil or repository.fetch_details == nil then
		load_tab(repo, { force_refresh = force_refresh })
		refresh()
		return
	end

	state.current_repo_details = "loading"
	update_spinner()
	render()
	state.requests.run(function(done)
		return repository.fetch_details(repo, { force_load = force_refresh }, done)
	end, function(details, err)
		if details then
			state.current_repo_details = details
		else
			state.current_repo_details = tostring(err or "Unknown error")
			notify.error("Failed to load repository: " .. tostring(err or "Unknown error"))
		end
		load_tab(repo, { force_refresh = force_refresh })
		refresh()
	end)
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("repo")
end

---@param repo PullsRepo
---@param opts { provider: PullsProvider|nil, force_refresh: boolean|nil }|nil
function M.open(repo, opts)
	opts = opts or {}
	local provider = opts.provider or state.provider
	if provider == nil then
		notify.error("Repository provider unavailable")
		return
	end

	state.win, state.buf = detail_ui.open("repo", cleanup, render)
	set_provider(provider)
	M.select(repo, { force_refresh = opts.force_refresh })
end

---@param repo PullsRepo|nil
function M.refresh(repo)
	local current = state.current_repo
	if M.is_open() and current and (repo == nil or tostring(current.id or "") == tostring(repo.id or "")) then
		M.select(current, { force_refresh = true })
	end
end

---@param repo PullsRepo
---@param opts { force_refresh: boolean|nil }|nil
function M.select(repo, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}

	local same_repo = state.current_repo ~= nil and tostring(state.current_repo.id or "") == tostring(repo.id or "")
	if
		same_repo
		and opts.force_refresh ~= true
		and (state.current_repo_details == "loading" or type(state.current_repo_details) == "table")
	then
		state.current_repo = repo
		render()
		return
	end

	clear_repo()
	load_repo(repo, opts.force_refresh == true)
end

---@param step 1|-1
local function change_tab(step)
	if not M.is_open() then
		return
	end
	local tabs = state.tabs
	if #tabs == 0 then
		return
	end
	local old_key = state.current_tab
	local idx = 1
	for i, tab in ipairs(tabs) do
		if tab.key == old_key then
			idx = i
			break
		end
	end
	set_tab(tabs[(idx - 1 + step) % #tabs + 1].key)
	if state.current_repo ~= nil then
		load_tab(state.current_repo, nil)
	end
	render()
end

function M.next_tab()
	change_tab(1)
end

function M.prev_tab()
	change_tab(-1)
end

function M.close()
	if M.is_open() then
		detail_ui.close()
	end
end

return M
