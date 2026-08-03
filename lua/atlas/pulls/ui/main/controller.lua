local M = {}

local statusline = require("atlas.ui.statusline")
local status_spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pulls.state")
local layout = require("atlas.ui.layout")
local helper = require("atlas.pulls.ui.main.helper")
local navigation = require("atlas.ui.navigation")

local active_pullrequests_handle = nil
local active_pr_reload_handles = {}

local function render_if_active()
	if not layout.is_open() then
		return
	end
	local ui_main_state = require("atlas.ui.state")
	local provider = state.provider
	if provider == nil or ui_main_state.current_view ~= provider.id then
		return
	end
	require("atlas.pulls.ui.main").render()
end

local refresh_status_spinner = status_spinner.create({
	interval_ms = 120,
	on_tick = function(frame)
		state.reload_spinner_frame = frame
		render_if_active()
	end,
})

---@return boolean
local function has_reloading_prs()
	for _, count in pairs(state.reloading_pr_keys or {}) do
		if (tonumber(count) or 0) > 0 then
			return true
		end
	end
	return false
end

---@param repo_id string
---@param pr_id string|number
local function begin_pr_reload(repo_id, pr_id)
	local key = state.reload_key(repo_id, pr_id)
	state.reloading_pr_keys[key] = (tonumber(state.reloading_pr_keys[key]) or 0) + 1

	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end

	state.reload_spinner_frame = refresh_status_spinner:current_frame()
	render_if_active()
end

---@param repo_id string
---@param pr_id string|number
local function end_pr_reload(repo_id, pr_id)
	local key = state.reload_key(repo_id, pr_id)
	local next_count = (tonumber(state.reloading_pr_keys[key]) or 0) - 1
	if next_count > 0 then
		state.reloading_pr_keys[key] = next_count
	else
		state.reloading_pr_keys[key] = nil
	end

	if not has_reloading_prs() then
		refresh_status_spinner:stop()
		state.reload_spinner_frame = "⠋"
	end

	render_if_active()
end

local function cancel_pr_reload_handles()
	for _, handle in ipairs(active_pr_reload_handles) do
		if handle ~= nil and handle.cancel then
			pcall(handle.cancel)
		end
	end
	active_pr_reload_handles = {}
end

local function reset_reload_state()
	refresh_status_spinner:stop()
	state.reloading_pr_keys = {}
	state.reload_spinner_frame = "⠋"
end

local function cancel_active_requests()
	if active_pullrequests_handle ~= nil and active_pullrequests_handle.cancel then
		pcall(active_pullrequests_handle.cancel)
	end
	active_pullrequests_handle = nil

	cancel_pr_reload_handles()
	reset_reload_state()
end

---@return integer
local function next_request_token()
	state.request_seq = (state.request_seq or 0) + 1
	return state.request_seq
end

---@param on_done fun(err: string|nil)
local function get_current_user(on_done)
	if state.current_user ~= nil then
		on_done(nil)
		return
	end
	local provider = state.provider
	if provider == nil then
		on_done("no provider")
		return
	end
	provider.fetch_user(function(user, err)
		if err ~= nil then
			on_done(tostring(err))
			return
		end
		state.current_user = user
		on_done(nil)
	end)
end

---@param opts { force_load: boolean }|nil
---@param on_done fun()|nil
local function load_active_view(opts, on_done)
	on_done = on_done or function() end
	opts = opts or { force_load = false }

	local provider = state.provider
	if provider == nil then
		on_done()
		return
	end

	local target_view = state.active_view
	if target_view == nil then
		statusline.notify("error", "No active view selected")
		on_done()
		return
	end

	if target_view._kind == "bookmarks" then
		cancel_active_requests()
		state.is_loading = false
		state.error = nil
		state.pulls = nil
		state.last_search_query = nil
		state.current_view = state.active_view
		render_if_active()
		on_done()
		return
	end

	local target_view_id = helper.view_id(target_view)
	local token = next_request_token()
	state.latest_request_tokens[target_view_id] = token
	cancel_active_requests()

	state.is_loading = true
	state.error = nil
	statusline.notify("loading", "Loading pull requests...")
	render_if_active()

	---@return boolean
	local function is_stale_request()
		if not helper.same_view(state.active_view, target_view) then
			return true
		end
		if state.latest_request_tokens[target_view_id] ~= token then
			return true
		end
		return false
	end

	---@param groups PullsGroup[]|nil
	---@param err string[]|string|nil
	local function finalize_fetch(groups, err)
		if is_stale_request() then
			return
		end
		state.is_loading = false
		state.current_view = state.active_view

		local first_err = nil
		if type(err) == "table" then
			first_err = err[1]
		elseif err ~= nil then
			first_err = err
		end

		local has_groups = #(groups or {}) > 0

		if first_err ~= nil then
			if has_groups then
				state.error = nil
				state.pulls = groups
				statusline.notify("warn", string.format("Some repositories failed: %s", tostring(first_err)))
			else
				state.error = tostring(first_err)
				state.pulls = {}
				statusline.notify("error", string.format("Failed to fetch pull requests: %s", tostring(first_err)))
			end
		else
			state.error = nil
			state.pulls = groups or {}
			statusline.notify("success", "Pull requests loaded", 1200)
		end

		render_if_active()
		on_done()
	end

	local function fetch_pull_requests()
		if is_stale_request() then
			return
		end
		active_pullrequests_handle = provider.fetch_pullrequests(
			target_view,
			{ force_load = opts.force_load == true },
			function(groups, err)
				active_pullrequests_handle = nil
				finalize_fetch(groups, err)
			end
		)
	end

	if state.current_user == nil then
		get_current_user(function(user_err)
			if is_stale_request() then
				return
			end
			if user_err then
				statusline.notify("warn", string.format("Failed to fetch current user: %s", tostring(user_err)))
			else
				render_if_active()
			end
			fetch_pull_requests()
		end)
	else
		fetch_pull_requests()
	end
end

---@param on_done fun()|nil
function M.refresh_current_view(on_done)
	load_active_view({ force_load = true }, function()
		navigation.focus_first_item()
		if on_done ~= nil then
			on_done()
		end
	end)
end

---@param pr PullRequest|nil
---@param on_done fun()|nil
function M.refresh_pr(pr, on_done)
	on_done = on_done or function() end

	if pr == nil or pr.id == nil then
		statusline.notify("warn", "No PR selected")
		on_done()
		return
	end

	local provider = state.provider
	if provider == nil or provider.fetch_pullrequest == nil then
		statusline.notify("warn", "Provider does not support single PR refresh")
		on_done()
		return
	end

	local pr_id = pr.id
	local repo_id = tostring(pr.repo_full_name or "")

	statusline.notify("loading", string.format("Reloading PR #%s...", tostring(pr_id)))
	begin_pr_reload(repo_id, pr_id)

	local panel = require("atlas.pulls.ui.panel")
	if panel.is_open() then
		local root_panel_state = require("atlas.pulls.ui.panel.state")
		local selected_repo = nil
		local current_item = navigation.current_item()
		if type(current_item) == "table" and type(current_item.repo) == "table" then
			selected_repo = current_item.repo
		end
		if root_panel_state.current_panel == "repo" then
			panel.on_select(pr, selected_repo, { force_refresh = true })
		else
			panel.on_select(pr, nil, { force_refresh = true })
		end
	end

	local reload_handle = nil
	reload_handle = provider.fetch_pullrequest(pr, { force_load = true }, function(fetched_pr, err)
		for i = #active_pr_reload_handles, 1, -1 do
			if active_pr_reload_handles[i] == reload_handle then
				table.remove(active_pr_reload_handles, i)
				break
			end
		end

		if err ~= nil or fetched_pr == nil then
			end_pr_reload(repo_id, pr_id)
			statusline.notify("error", tostring(err or "Failed to reload PR"))
			on_done()
			return
		end

		local groups = state.pulls or {}
		local replaced = false
		for _, group in ipairs(groups) do
			if group.repo.id == repo_id then
				for i, existing_pr in ipairs(group.prs or {}) do
					if existing_pr.id == pr_id then
						group.prs[i] = fetched_pr
						replaced = true
						break
					end
				end
			end
			if replaced then
				break
			end
		end

		state.pulls = groups
		end_pr_reload(repo_id, pr_id)

		if panel.is_open() then
			panel.on_select(fetched_pr, nil)
		end

		statusline.notify("success", string.format("Reloaded PR #%s", tostring(pr_id)), 1200)
		on_done()
	end)
	table.insert(active_pr_reload_handles, reload_handle)
end

---@param view AtlasPullsViewConfig
function M.switch_view(view)
	state.active_view = view
	load_active_view({ force_load = false }, function()
		navigation.focus_first_item()
	end)
end

---@param name string
---@param value any
function M.run_bookmark(name, value)
	local provider = state.provider
	if provider == nil then
		return
	end
	local view = { name = name, layout = "compact" }
	if type(value) == "string" then
		view.search = value
	elseif type(value) == "table" then
		for k, v in pairs(value) do
			view[k] = v
		end
	end

	cancel_active_requests()
	state.is_loading = true
	state.error = nil
	state.pulls = nil
	statusline.notify("loading", "Running query...")
	render_if_active()

	active_pullrequests_handle = provider.fetch_pullrequests(view, { force_load = false }, function(groups, err)
		active_pullrequests_handle = nil
		state.is_loading = false
		local first_err = type(err) == "table" and err[1] or err
		if first_err and (groups == nil or #groups == 0) then
			state.error = tostring(first_err)
			state.pulls = {}
			statusline.notify("error", string.format("Query failed: %s", state.error))
		else
			state.error = nil
			state.pulls = groups or {}
			statusline.notify("success", "Pull requests loaded", 1200)
		end
		render_if_active()
	end)
end

---@param status string
function M.toggle_status_filter(status)
	-- Don't allow deselecting the last active filter
	local active_count = 0
	for _, enabled in pairs(state.status_filters or {}) do
		if enabled then
			active_count = active_count + 1
		end
	end
	if state.status_filters[status] and active_count <= 1 then
		statusline.notify("warn", "At least one status filter must remain active")
		return
	end

	state.status_filters[status] = not state.status_filters[status]
	load_active_view({ force_load = true }, function()
		navigation.focus_first_item()
	end)
end

return M
