local M = {}

local shared_detail = require("atlas.ui.detail")
local providers = require("atlas.providers")
local resolver = require("atlas.providers.resolve")
local detail_state = require("atlas.pulls.ui.detail.state")
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
		icon = overview_icon,
		icon_hl = overview_icon_hl,
		mod = require("atlas.pulls.ui.detail.tabs.overview"),
	},
}

---@return PullsDetailTab[]
local function get_tabs()
	local provider = detail_state.provider
	local detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
	local tabs = detail and detail.tabs and detail.tabs()
	return tabs and #tabs > 0 and tabs or DEFAULT_TABS
end

---@param tab_key string
---@return PullsDetailTab|nil
local function get_tab(tab_key)
	for _, tab in ipairs(get_tabs()) do
		if tab.key == tab_key then
			return tab
		end
	end
	return nil
end

---@param tab_key string
---@return PullsDetailTabModule|nil
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
	if detail_state.current_pr == nil then
		return false
	end
	if detail_state.header_loading or detail_state.diffstat == "loading" or detail_state.pipelines == "loading" then
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
			if not shared_detail.is_showing("pulls") or not is_loading() then
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
	if shared_detail.is_showing("pulls") then
		M.render()
	end
end

local function scroll_to_top()
	local win = detail_state.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end
end

local function activate_current_tab()
	local buf = detail_state.buf
	local tab = get_tab(detail_state.current_tab)
	if tab == nil then
		return
	end
	if tab.mod.activate then
		tab.mod.activate(buf, refresh)
	end
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) and tab.keymaps then
		tab.keymaps.register(buf)
	end
end

---@param old_key string|nil
---@param new_key string|nil
local function switch_tab_keymaps(old_key, new_key)
	local buf = detail_state.buf
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
		require("atlas.pulls.ui.detail.keymaps").register(buf)
	end

	if new_key and old_key ~= new_key then
		local new_tab = get_tab(new_key)
		if new_tab then
			if new_tab.mod.activate then
				new_tab.mod.activate(buf, refresh)
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
	local current = detail_state.current_pr
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
		if shared_detail.is_showing("pulls") then
			M.render()
		end
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
local function load_active_tab(pr, opts)
	local tab_mod = get_tab_module(detail_state.current_tab)
	if tab_mod and tab_mod.on_select then
		tab_mod.on_select(pr, make_refresh_callback(pr), opts)
	end
end

local requests = request_scope.new()
local target_message = nil

local function cancel_requests()
	requests.cancel()
	requests = request_scope.new()
end

---@param message string
local function render_target_message(message)
	local buf = detail_state.buf
	local win = detail_state.win
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	detail_state.line_map = {}
	vim.api.nvim_set_option_value("winbar", "", { win = win, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. message })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil, details: PullRequestDetails|nil }|nil
local function fetch_details(pr, opts)
	cancel_requests()

	local provider = detail_state.provider
	if provider == nil then
		return
	end

	local tab_refresh = make_refresh_callback(pr)
	local force_refresh = opts and opts.force_refresh == true
	local core = provider.capabilities.core
	local provider_detail = provider.capabilities.ui and provider.capabilities.ui.detail
	detail_state.header_loading = true

	---@param details PullRequestDetails
	local function use_details(details)
		if not is_current_pr(pr) then
			return
		end
		detail_state.current_details = details

		if provider_detail and provider_detail.fetch_header then
			tab_refresh()
			requests.run(function(done)
				return provider_detail.fetch_header(details, opts, done)
			end, function()
				if not is_current_pr(pr) then
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
	else
		requests.run(function(done)
			return core.fetch_pullrequest(pr, { force_load = force_refresh }, done)
		end, function(details, err)
			if not is_current_pr(pr) then
				return
			end
			if details == nil then
				detail_state.header_loading = false
				notify.error(tostring(err or "Failed to load pull request"))
				tab_refresh()
				return
			end
			use_details(details)
		end)
	end

	if core.fetch_diffstat then
		detail_state.diffstat = "loading"
		requests.run(function(done)
			return core.fetch_diffstat(pr, { force_refresh = force_refresh }, done)
		end, function(entries, err)
			if not is_current_pr(pr) then
				return
			end
			detail_state.diffstat = err and err or (entries or {})
			tab_refresh()
		end)
	end

	local pipelines = provider.capabilities.pipelines
	if pipelines then
		detail_state.pipelines = "loading"
		requests.run(function(done)
			return pipelines.fetch(pr, { force_refresh = force_refresh }, done)
		end, function(items, err)
			if not is_current_pr(pr) then
				return
			end
			detail_state.pipelines = err and err or (items or {})
			tab_refresh()
		end)
	end
end

local function cleanup()
	local buf = detail_state.buf
	switch_tab_keymaps(detail_state.current_tab, nil)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		detail_keymaps.remove(buf)
	end
	stop_spinner()
	cancel_requests()
	reset_tabs()
	detail_state.reset()
	target_message = nil
end

-- Public API

---@return boolean
function M.is_open()
	return shared_detail.is_showing("pulls", vim.api.nvim_get_current_tabpage())
end

function M.render()
	if target_message ~= nil then
		render_target_message(target_message)
		return
	end
	renderer.render(get_tabs(), get_tab_module)
end

---@param pr PullRequest|nil
---@param opts { force_refresh: boolean|nil, details: PullRequestDetails|nil }|nil
function M.select(pr, opts)
	opts = opts or {}
	target_message = nil

	local same_pr = pr ~= nil
		and detail_state.current_pr ~= nil
		and tostring(detail_state.current_pr.id) == tostring(pr.id)
		and tostring(detail_state.current_pr.repo_full_name) == tostring(pr.repo_full_name)
	local context_changed = pr ~= nil and not same_pr
	local should_fetch = context_changed
		or opts.force_refresh == true
		or (detail_state.current_details == nil and detail_state.header_loading ~= true)

	detail_state.current_pr = pr
	if detail_state.current_pr == nil then
		detail_state.current_details = nil
		return
	end
	if should_fetch then
		detail_state.current_details = nil
	end

	local buf = detail_state.buf
	if buf then
		detail_keymaps.register(buf)
	end
	activate_current_tab()

	if not same_pr and pr ~= nil then
		local old_key = detail_state.current_tab
		if detail_state.current_tab == nil then
			detail_state.current_tab = get_tabs()[1].key
		end
		switch_tab_keymaps(old_key, detail_state.current_tab)
		stop_spinner()
	end

	if context_changed or opts.force_refresh == true then
		reset_tabs()
		detail_state.diffstat = nil
		detail_state.pipelines = nil
		detail_state.header_loading = false
	end

	if should_fetch then
		load_active_tab(detail_state.current_pr, { force_refresh = opts.force_refresh == true })
		fetch_details(detail_state.current_pr, opts)
		update_spinner()
	end

	if shared_detail.is_showing("pulls") then
		M.render()
	end
end

---@param input PullRequest|AtlasTarget
---@param opts { provider: PullsProvider|nil, current_user: PullsUser|nil, force_refresh: boolean|nil, on_update: fun(pr: PullRequest, result: PullsActionResult|nil)|nil }|nil
function M.open(input, opts)
	opts = opts or {}

	---@type AtlasTarget|nil
	local target
	if input.domain == "pulls" then
		---@cast input AtlasTarget
		target = input
	end
	local provider_id = target and target.provider or input.provider
	local provider = opts.provider or (provider_id and providers.load(provider_id, "pulls")) or detail_state.provider
	---@cast provider PullsProvider|nil
	if provider == nil then
		notify.error("Pull request provider unavailable")
		return
	end
	local previous_provider = detail_state.provider
	if previous_provider and previous_provider ~= provider then
		switch_tab_keymaps(detail_state.current_tab, nil)
		stop_spinner()
		cancel_requests()
		reset_tabs()
		detail_state.current_pr = nil
		detail_state.current_details = nil
		detail_state.current_tab = "overview"
		detail_state.header_loading = false
	end
	detail_state.win, detail_state.buf = shared_detail.open("pulls", cleanup, M.render)
	detail_state.provider = provider
	detail_state.current_user = opts.current_user
		or (previous_provider == provider and detail_state.current_user or nil)
	detail_state.on_update = opts.on_update

	require("atlas.pulls.ui.highlights").setup()
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
		---@cast input PullRequest
		M.select(input, {
			force_refresh = opts.force_refresh,
			details = input.description ~= nil and input or nil,
		})
		return
	end

	local ref = resolver.pull_request_ref(target)
	cancel_requests()
	stop_spinner()
	detail_state.current_pr = nil
	detail_state.current_details = nil
	detail_state.diffstat = nil
	detail_state.pipelines = nil
	detail_state.header_loading = true
	detail_state.line_map = {}
	target_message = "Loading pull request..."
	detail_keymaps.register(detail_state.buf)
	M.render()
	requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequest(ref, { force_load = opts.force_refresh == true }, done)
	end, function(pr, err)
		if pr == nil then
			detail_state.header_loading = false
			target_message = tostring(err or "Failed to load pull request")
			M.render()
			notify.error(target_message)
			return
		end
		M.select(pr, { details = pr })
	end)
end

function M.refresh()
	if detail_state.current_pr then
		M.select(detail_state.current_pr, { force_refresh = true })
	end
end

---@param pr PullRequest
---@param result PullsActionResult|nil
function M.action_result(pr, result)
	if result and result.changed_pr then
		if detail_state.on_update then
			detail_state.on_update(pr, result)
		else
			M.select(pr, { force_refresh = true })
		end
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

	if detail_state.current_pr then
		load_active_tab(detail_state.current_pr)
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
	if shared_detail.is_showing("pulls") then
		shared_detail.close()
	end
end

return M
