local M = {}

local shared_detail = require("atlas.ui.detail")
local detail_state = require("atlas.issues.ui.detail.state")
local renderer = require("atlas.issues.ui.detail.renderer")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local SPINNER_INTERVAL_MS = 100

---@return IssuesDetailTab[]
local function get_tabs()
	local provider = detail_state.provider
	local detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
	return detail and detail.tabs and detail.tabs() or {}
end

---@param tab_key string
---@return IssuesDetailTabModule|nil
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
local requests = request_scope.new()

local function cancel_requests()
	requests.cancel()
	requests = request_scope.new()
end

local function stop_spinner()
	if spinner_timer ~= nil then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

local function is_loading()
	local issue = detail_state.current_issue
	if issue == nil then
		return false
	end
	if detail_state.header_loading then
		return true
	end
	local tab = get_tab_module(detail_state.current_tab)
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
			if not shared_detail.is_showing("issues") or not is_loading() then
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

local function refresh()
	if shared_detail.is_showing("issues") then
		M.render()
	end
end

local function scroll_to_top()
	local win = detail_state.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
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

---@param issue Issue|nil
---@return boolean
local function is_current_issue(issue)
	local current = detail_state.current_issue
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
		if shared_detail.is_showing("issues") then
			M.render()
		end
	end
end

---@type fun(issue: IssueDetails, opts: { force_refresh: boolean|nil }|nil)
local load_active_tab

---@param issue Issue
---@param opts { force_refresh: boolean|nil, details: IssueDetails|nil }|nil
local function fetch_details(issue, opts)
	cancel_requests()

	local provider = detail_state.provider
	if provider == nil then
		return
	end

	local provider_detail = provider.capabilities.ui and provider.capabilities.ui.detail
	local tab_refresh = make_refresh_callback(issue)
	local force_refresh = opts and opts.force_refresh == true
	detail_state.header_loading = true

	---@param details IssueDetails
	local function use_details(details)
		if not is_current_issue(issue) then
			return
		end
		detail_state.current_details = details
		load_active_tab(details, { force_refresh = force_refresh })

		if provider_detail and provider_detail.fetch_header then
			tab_refresh()
			requests.run(function(done)
				return provider_detail.fetch_header(issue, details, opts, done)
			end, function()
				if not is_current_issue(issue) then
					return
				end
				detail_state.header_loading = false
				tab_refresh()
			end)
		else
			detail_state.header_loading = false
			tab_refresh()
		end
	end

	if opts and opts.details then
		use_details(opts.details)
		return
	end

	requests.run(function(done)
		return provider.capabilities.core.fetch_issue(tostring(issue.key or ""), { force_load = force_refresh }, done)
	end, function(details, err)
		if not is_current_issue(issue) then
			return
		end
		if details == nil then
			detail_state.header_loading = false
			notify.error(tostring(err or "Failed to load issue"))
			tab_refresh()
			return
		end
		use_details(details)
	end)
end

---@param issue IssueDetails
---@param opts { force_refresh: boolean|nil }|nil
load_active_tab = function(issue, opts)
	local tab_mod = get_tab_module(detail_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(issue, make_refresh_callback(issue), opts)
	end
end

local function cleanup()
	local buf = detail_state.buf
	switch_tab_keymaps(detail_state.current_tab, nil)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		require("atlas.issues.ui.detail.keymaps").remove(buf)
	end
	stop_spinner()
	cancel_requests()
	reset_tabs()
	detail_state.reset()
end

-- Public API

---@return boolean
function M.is_open()
	return shared_detail.is_showing("issues", vim.api.nvim_get_current_tabpage())
end

function M.render()
	renderer.render(get_tabs(), get_tab_module)
end

---@param issue Issue|nil
---@param opts { force_refresh: boolean|nil, details: IssueDetails|nil }|nil
function M.select(issue, opts)
	opts = opts or {}

	local same_issue = issue ~= nil
		and detail_state.current_issue ~= nil
		and tostring(detail_state.current_issue.key) == tostring(issue.key)
	local context_changed = issue ~= nil and not same_issue

	if issue ~= nil then
		detail_state.current_issue = issue
	end

	if detail_state.current_issue == nil then
		detail_state.current_details = nil
		return
	end

	if detail_state.buf and vim.api.nvim_buf_is_valid(detail_state.buf) then
		require("atlas.issues.ui.detail.keymaps").register(detail_state.buf)
	end

	local should_fetch = context_changed
		or opts.force_refresh == true
		or (detail_state.current_details == nil and detail_state.header_loading ~= true)
	if should_fetch then
		detail_state.current_details = nil
	end

	if not same_issue and issue ~= nil then
		local old_key = detail_state.current_tab
		local tabs = get_tabs()
		local valid = false
		for _, t in ipairs(tabs) do
			if t.key == detail_state.current_tab then
				valid = true
				break
			end
		end
		if not valid then
			detail_state.current_tab = tabs[1] and tabs[1].key or nil
		end
		switch_tab_keymaps(old_key, detail_state.current_tab)
		stop_spinner()
	else
		switch_tab_keymaps(nil, detail_state.current_tab)
	end

	if context_changed or opts.force_refresh == true then
		reset_tabs()
	end

	if should_fetch then
		fetch_details(detail_state.current_issue, opts)
		update_spinner()
	end

	if shared_detail.is_showing("issues") then
		M.render()
	end
end

---@param input Issue|AtlasTarget
---@param opts { provider: IssuesProvider|nil, current_user: IssueUser|nil, force_refresh: boolean|nil, on_update: fun(issue: Issue|nil, result: IssuesActionResult|nil)|nil }|nil
function M.open(input, opts)
	opts = opts or {}

	---@type AtlasTarget|nil
	local target
	if input.domain == "issues" then
		---@cast input AtlasTarget
		target = input
	end
	local provider = opts.provider or (target and providers.load(target.provider, "issues")) or detail_state.provider
	---@cast provider IssuesProvider|nil
	if provider == nil then
		notify.error("Issue provider unavailable")
		return
	end
	local previous_provider = detail_state.provider
	if previous_provider and previous_provider ~= provider then
		switch_tab_keymaps(detail_state.current_tab, nil)
		stop_spinner()
		cancel_requests()
		reset_tabs()
		detail_state.current_issue = nil
		detail_state.current_details = nil
		detail_state.current_tab = nil
		detail_state.header_loading = false
	end
	detail_state.win, detail_state.buf = shared_detail.open("issues", cleanup, M.render)
	detail_state.provider = provider
	detail_state.current_user = opts.current_user
		or (previous_provider == provider and detail_state.current_user or nil)
	detail_state.on_update = opts.on_update

	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	if detail_state.current_user == nil then
		provider.capabilities.core.fetch_user(function(user)
			if detail_state.provider == provider then
				detail_state.current_user = user
				refresh()
			end
		end)
	end

	if target == nil then
		---@cast input Issue
		M.select(input, {
			force_refresh = opts.force_refresh,
			details = input.description ~= nil and input or nil,
		})
		return
	end

	local key = provider.issue_key(target)
	if key == nil then
		notify.error("Could not determine issue key")
		return
	end

	---@type Issue
	local issue = { key = key, title = "Loading issue...", url = target.url }
	M.select(issue, { force_refresh = opts.force_refresh })
end

function M.refresh()
	if detail_state.current_issue then
		M.select(detail_state.current_issue, { force_refresh = true })
	end
end

---@param result IssuesActionResult|nil
function M.action_result(result)
	if result == nil or result.issue_key == nil then
		return
	end
	if result.removed then
		if detail_state.on_update then
			detail_state.on_update(nil, result)
		end
		M.close()
		return
	end
	if detail_state.on_update then
		detail_state.on_update(nil, result)
	else
		M.refresh()
	end
end

---@param step 1|-1
local function change_tab(step)
	local tabs = get_tabs()
	if #tabs == 0 then
		return
	end
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

	if detail_state.current_details then
		load_active_tab(detail_state.current_details)
		update_spinner()
	end

	M.render()
	scroll_to_top()
end

function M.next_tab()
	change_tab(1)
end

function M.prev_tab()
	change_tab(-1)
end

function M.close()
	if shared_detail.is_showing("issues") then
		shared_detail.close()
	end
end

return M
