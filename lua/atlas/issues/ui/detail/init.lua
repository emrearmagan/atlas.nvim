local M = {}

local detail_window = require("atlas.issues.ui.detail.window")
local renderer = require("atlas.issues.ui.detail.renderer")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local links = require("atlas.ui.links")
local state = require("atlas.issues.ui.detail.state")

local SPINNER_INTERVAL_MS = 100

---@type IssueRef|nil
local pending_ref = nil

local function reset_tabs()
	for _, tab in ipairs(state.tabs) do
		if tab.mod.reset then
			tab.mod.reset()
		end
	end
end

local function cancel_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

local function stop_spinner()
	if state.spinner_timer ~= nil then
		state.spinner_timer:stop()
		state.spinner_timer:close()
		state.spinner_timer = nil
	end
end

local function is_loading()
	if state.issue_loading or state.details_loading or (state.links and state.links.loading) then
		return true
	end
	if state.current_issue == nil then
		return false
	end
	local tab = state.tab_module(state.current_tab)
	return tab ~= nil and tab.is_loading ~= nil and tab.is_loading()
end

local function render()
	renderer.render()
end

local function start_spinner()
	if state.spinner_timer ~= nil then
		return
	end
	state.spinner_timer = vim.uv.new_timer()
	if state.spinner_timer == nil then
		return
	end
	state.spinner_timer:start(
		SPINNER_INTERVAL_MS,
		SPINNER_INTERVAL_MS,
		vim.schedule_wrap(function()
			if not detail_window.is_open() or not is_loading() then
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
	if detail_window.is_open() then
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
		local old_tab = state.tab_module(old_key)
		if old_tab and old_tab.deactivate then
			old_tab.deactivate(buf)
		end
	end

	state.current_tab = tab_key
	if tab_key then
		local new_tab = state.tab_module(tab_key)
		if new_tab and new_tab.activate then
			new_tab.activate(buf, render_if_open)
		end
	end
end

---@param left IssueRef|nil
---@param right IssueRef|nil
---@return boolean
local function same_ref(left, right)
	return left ~= nil and right ~= nil and left.key == right.key
end

---@param issue Issue
---@return fun()
local function refresh_callback(issue)
	return function()
		if not same_ref(state.current_issue, issue) then
			return
		end
		update_spinner()
		render_if_open()
	end
end

---@param issue Issue
---@param force_refresh boolean
local function load_links(issue, force_refresh)
	local provider = state.provider
	local current = { items = {}, loading = provider ~= nil }
	state.links = current
	if provider == nil then
		return
	end
	local refresh = refresh_callback(issue)
	state.requests.run(function(done)
		return links.fetch(provider, issue, { force_refresh = force_refresh }, done)
	end, function(items, err)
		if state.links ~= current then
			return
		end
		current.items = items or {}
		current.error = err
		current.loading = false
		refresh()
	end)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
local function load_active_tab(issue, opts)
	local tab = state.tab_module(state.current_tab)
	if tab and tab.on_select then
		tab.on_select(issue, refresh_callback(issue), opts)
	end
end

---@param ref IssueRef
---@param force_refresh boolean
local function load_details(ref, force_refresh)
	local provider = state.provider
	if provider == nil then
		return
	end

	state.details_loading = true
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_issue(ref, { force_refresh = force_refresh }, done)
	end, function(fetched_details, err)
		if state.provider ~= provider or not same_ref(state.current_issue or pending_ref, ref) then
			return
		end
		state.details_loading = false
		if fetched_details == nil then
			notify.error(tostring(err or "Failed to load issue details"))
		else
			state.current_details = fetched_details
		end
		update_spinner()
		render_if_open()
	end)
end

local function clear_issue()
	stop_spinner()
	cancel_requests()
	reset_tabs()
	pending_ref = nil
	state.current_issue = nil
	state.current_details = nil
	state.details_loading = false
	state.issue_loading = false
	state.line_map = {}
	state.links = { items = {}, loading = false }
end

---@param issue Issue
---@param force_refresh boolean
local function show_issue(issue, force_refresh)
	state.current_issue = issue
	pending_ref = nil
	state.issue_loading = false
	load_links(issue, force_refresh)
	load_active_tab(issue, { force_refresh = force_refresh })
	update_spinner()
	render()
end

---@param provider IssuesProvider
local function set_provider(provider)
	if state.provider == provider then
		return
	end

	set_tab(nil)
	clear_issue()
	state.provider = provider
	state.provider_detail = provider.capabilities.ui and provider.capabilities.ui.detail or nil
	state.tabs = state.provider_detail and state.provider_detail.tabs and state.provider_detail.tabs() or {}

	local first_tab = state.tabs[1]
	set_tab(first_tab and first_tab.key or nil)
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		require("atlas.issues.ui.detail.keymaps").register(state.buf)
	end
end

local function cleanup()
	local buf = state.buf
	set_tab(nil)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		require("atlas.issues.ui.detail.keymaps").remove(buf)
	end
	stop_spinner()
	reset_tabs()
	pending_ref = nil
	state.reset()
end

---@return boolean
function M.is_open()
	return detail_window.is_open()
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
function M.select(issue, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}

	if
		same_ref(state.current_issue, issue)
		and opts.force_refresh ~= true
		and (state.details_loading or state.current_details)
	then
		state.current_issue = issue
		render()
		return
	end

	clear_issue()
	state.details_loading = true
	show_issue(issue, opts.force_refresh == true)
	load_details(issue, opts.force_refresh == true)
end

---@param opts { provider: IssuesProvider|nil, force_refresh: boolean|nil, on_update: fun(issue: Issue|nil, result: IssuesActionResult|nil)|nil, back: fun()|nil }|nil
---@return IssuesProvider|nil, boolean force_refresh
local function prepare_open(opts)
	opts = opts or {}
	local provider = opts.provider or state.provider
	---@cast provider IssuesProvider|nil
	if provider == nil then
		notify.error("Issue provider unavailable")
		return nil, false
	end

	state.win, state.buf = detail_window.open(cleanup, render)
	set_provider(provider)
	state.on_update = opts.on_update
	state.back = opts.back

	return provider, opts.force_refresh == true
end

---@param issue Issue
---@param opts { provider: IssuesProvider|nil, force_refresh: boolean|nil, on_update: fun(issue: Issue|nil, result: IssuesActionResult|nil)|nil, back: fun()|nil }|nil
function M.open(issue, opts)
	local provider, force_refresh = prepare_open(opts)
	if provider == nil then
		return
	end
	M.select(issue, { force_refresh = force_refresh })
end

---@param ref IssueRef
---@param opts { provider: IssuesProvider|nil, force_refresh: boolean|nil, on_update: fun(issue: Issue|nil, result: IssuesActionResult|nil)|nil, back: fun()|nil }|nil
function M.open_ref(ref, opts)
	local provider, force_refresh = prepare_open(opts)
	if provider == nil then
		return
	end
	if
		not force_refresh
		and same_ref(state.current_issue or pending_ref, ref)
		and (state.issue_loading or state.details_loading or state.current_details)
	then
		render()
		return
	end

	clear_issue()
	pending_ref = ref
	state.issue_loading = true
	load_details(ref, force_refresh)
	update_spinner()
	render()
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = force_refresh }, done)
	end, function(issues, err)
		if state.provider ~= provider or not same_ref(pending_ref, ref) then
			return
		end
		local loaded_issue = issues and issues[1] or nil
		if loaded_issue == nil then
			pending_ref = nil
			state.issue_loading = false
			state.details_loading = false
			state.current_details = nil
			update_spinner()
			render()
			notify.error(tostring(err or "Failed to load issue"))
			return
		end
		show_issue(loaded_issue, force_refresh)
	end)
end

---@param ref IssueRef|nil
function M.refresh(ref)
	local issue = state.current_issue
	local provider = state.provider
	if not M.is_open() or issue == nil or provider == nil or (ref ~= nil and not same_ref(issue, ref)) then
		return
	end
	M.select(issue, { force_refresh = true })
	state.issue_loading = true
	update_spinner()
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ issue }, { force_refresh = true }, done)
	end, function(issues, err)
		if state.provider ~= provider or not same_ref(state.current_issue, issue) then
			return
		end
		state.issue_loading = false
		local fetched_issue = issues and issues[1] or nil
		if fetched_issue == nil then
			notify.error(tostring(err or "Failed to reload issue"))
		else
			state.current_issue = fetched_issue
		end
		update_spinner()
		render_if_open()
	end)
end

---@param step 1|-1
local function change_tab(step)
	local items = state.tabs
	if #items == 0 then
		return
	end
	local index = 1
	for i, tab in ipairs(items) do
		if tab.key == state.current_tab then
			index = i
			break
		end
	end

	set_tab(items[(index - 1 + step) % #items + 1].key)
	local issue = state.current_issue
	if issue then
		load_active_tab(issue)
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

-- This just reopens the same issue again. For example when opening something back and wanting to come back to this issue, like when opening a reference
---@return fun()|nil
function M.way_back()
	if state.back then
		return state.back
	end
	local issue, provider, on_update = state.current_issue, state.provider, state.on_update
	if issue == nil or provider == nil then
		return nil
	end
	return function()
		M.open(issue, { provider = provider, on_update = on_update })
	end
end

function M.close()
	if M.is_open() then
		detail_window.close()
	end
end

---@param issue Issue
---@param on_update (fun(issue: Issue|nil, result: IssuesActionResult|nil))|nil
---@param result IssuesActionResult|nil
function M.apply_action_result(issue, on_update, result)
	if not result or not result.issue_key then
		return
	end
	if on_update then
		on_update(issue, result)
		return
	end

	if result.removed then
		M.close()
	else
		M.refresh(issue)
	end
end

return M
