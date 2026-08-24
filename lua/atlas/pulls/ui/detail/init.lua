local M = {}

local detail_ui = require("atlas.ui.detail")
local providers = require("atlas.providers")
local state = require("atlas.pulls.ui.detail.state")
local renderer = require("atlas.pulls.ui.detail.renderer")
local detail_keymaps = require("atlas.pulls.ui.detail.keymaps")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local overview_icon, overview_icon_hl = icons.general("overview")

local SPINNER_INTERVAL_MS = 100

local DEFAULT_TABS = {
	{
		key = "overview",
		label = "Overview",
		icon = { icon = overview_icon, hl_group = overview_icon_hl },
		mod = require("atlas.pulls.ui.detail.tabs.overview"),
	},
}

---@param tab_key string
---@return PullsDetailTabModule|nil
local function tab_module(tab_key)
	for _, tab in ipairs(state.tabs) do
		if tab.key == tab_key then
			return tab.mod
		end
	end
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

-- Loading spinner

local function stop_spinner()
	if state.spinner_timer ~= nil then
		state.spinner_timer:stop()
		state.spinner_timer:close()
		state.spinner_timer = nil
	end
end

local function is_loading()
	if state.details_loading or state.diffstat == "loading" or state.pipelines == "loading" then
		return true
	end
	if state.current_pr == nil then
		return false
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
			if not detail_ui.is_showing("pulls") or not is_loading() then
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

local function render_if_open()
	if detail_ui.is_showing("pulls") then
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
		local old_tab = tab_module(old_key)
		if old_tab and old_tab.deactivate then
			old_tab.deactivate(buf)
		end
	end

	state.current_tab = tab_key
	if tab_key then
		local new_tab = tab_module(tab_key)
		if new_tab and new_tab.activate then
			new_tab.activate(buf, render_if_open)
		end
	end
end

---@param left PullRequestRef|nil
---@param right PullRequestRef|nil
---@return boolean
local function same_ref(left, right)
	return left ~= nil
		and tostring(left.id or "") == tostring(right and right.id or "")
		and tostring(left.repo_full_name or "") == tostring(right and right.repo_full_name or "")
end

---@type PullRequestRef|nil
local pending_ref = nil

---@param pr PullRequest
---@return fun()
local function refresh_callback(pr)
	return function()
		if not same_ref(state.current_pr, pr) then
			return
		end
		update_spinner()
		render_if_open()
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
local function load_active_tab(pr, opts)
	local tab_mod = tab_module(state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(pr, refresh_callback(pr), opts)
	end
end

local function cancel_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param force_refresh boolean
local function load_pr(pr, details, force_refresh)
	local provider = state.provider
	if provider == nil then
		return
	end

	local tab_refresh = refresh_callback(pr)
	local core = provider.capabilities.core
	state.details_loading = true

	if details then
		state.current_details = details
		state.details_loading = false
		load_active_tab(details, { force_refresh = force_refresh })
	else
		-- Start the active tab request alongside the details request. Targets are
		-- hydrated before reaching this function, so their requests remain sequential.
		load_active_tab(pr, { force_refresh = force_refresh })
		state.requests.run(function(done)
			return core.fetch_pullrequest(pr, { force_load = force_refresh }, done)
		end, function(fetched_details, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			if fetched_details == nil then
				state.details_loading = false
				notify.error(tostring(err or "Failed to load pull request"))
				tab_refresh()
				return
			end
			state.current_details = fetched_details
			state.details_loading = false
			tab_refresh()
		end)
	end

	if core.fetch_diffstat then
		state.diffstat = "loading"
		state.requests.run(function(done)
			return core.fetch_diffstat(pr, { force_refresh = force_refresh }, done)
		end, function(entries, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.diffstat = err and err or (entries or {})
			tab_refresh()
		end)
	end

	local pipelines = provider.capabilities.pipelines
	if pipelines then
		state.pipelines = "loading"
		state.requests.run(function(done)
			return pipelines.fetch(pr, { force_refresh = force_refresh }, done)
		end, function(items, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.pipelines = err and err or (items or {})
			tab_refresh()
		end)
	end
end

local function clear_pr()
	cancel_requests()
	stop_spinner()
	reset_tabs()
	pending_ref = nil
	state.current_pr = nil
	state.current_details = nil
	state.diffstat = nil
	state.pipelines = nil
	state.details_loading = false
	state.line_map = {}
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param force_refresh boolean
local function show_pr(pr, details, force_refresh)
	state.current_pr = pr
	pending_ref = nil
	load_pr(pr, details, force_refresh)
	update_spinner()
	render()
end

---@param provider PullsProvider
local function set_provider(provider)
	if state.provider == provider then
		return
	end

	set_tab(nil)
	clear_pr()
	state.provider = provider
	local detail = provider.capabilities.ui and provider.capabilities.ui.detail
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
	pending_ref = nil
	state.reset()
end

-- Public API

---@return boolean
function M.is_open()
	return detail_ui.is_showing("pulls")
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
function M.select(pr, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}

	local same_pr = same_ref(state.current_pr, pr)
	if same_pr and opts.force_refresh ~= true and (state.details_loading or state.current_details) then
		state.current_pr = pr
		render()
		return
	end

	clear_pr()
	local details = nil
	if opts.force_refresh ~= true and pr.description ~= nil then
		details = pr --[[@as PullRequestDetails]]
	end
	show_pr(pr, details, opts.force_refresh == true)
end

---@param input PullRequest|PullRequestRef
---@param opts { provider: PullsProvider|nil, force_refresh: boolean|nil, on_update: fun(pr: PullRequest, result: PullsActionResult|nil)|nil }|nil
function M.open(input, opts)
	opts = opts or {}

	---@type PullRequest|nil
	local pr = nil
	if input.title ~= nil then
		pr = input --[[@as PullRequest]]
	end
	local provider_id = pr and pr.provider or nil
	local provider = opts.provider or (provider_id and providers.load(provider_id, "pulls")) or state.provider
	---@cast provider PullsProvider|nil
	if provider == nil then
		notify.error("Pull request provider unavailable")
		return
	end
	state.win, state.buf = detail_ui.open("pulls", cleanup, render)
	set_provider(provider)
	state.on_update = opts.on_update

	require("atlas.pulls.ui.highlights").setup()
	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	if pr then
		M.select(pr, { force_refresh = opts.force_refresh })
		return
	end

	local ref = input
	if
		opts.force_refresh ~= true
		and same_ref(state.current_pr or pending_ref, ref)
		and (state.details_loading or state.current_details)
	then
		render()
		return
	end

	clear_pr()
	pending_ref = ref
	state.details_loading = true
	update_spinner()
	render()
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequest(ref, { force_load = opts.force_refresh == true }, done)
	end, function(loaded_pr, err)
		if state.provider ~= provider or not same_ref(pending_ref, ref) then
			return
		end
		if loaded_pr == nil then
			pending_ref = nil
			state.details_loading = false
			update_spinner()
			render()
			notify.error(tostring(err or "Failed to load pull request"))
			return
		end
		show_pr(loaded_pr, loaded_pr, opts.force_refresh == true)
	end)
end

---@param ref PullRequestRef|nil
function M.refresh(ref)
	if M.is_open() and state.current_pr and (ref == nil or same_ref(state.current_pr, ref)) then
		M.select(state.current_pr, { force_refresh = true })
	end
end

---@param step 1|-1
local function change_tab(step)
	if not M.is_open() then
		return
	end
	local items = state.tabs
	if #items == 0 then
		return
	end
	local old_key = state.current_tab
	local idx = 1
	for i, tab in ipairs(items) do
		if tab.key == old_key then
			idx = i
			break
		end
	end

	set_tab(items[(idx - 1 + step) % #items + 1].key)

	local pr = state.current_details or state.current_pr
	if pr then
		load_active_tab(pr)
		update_spinner()
	end

	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
	end
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
