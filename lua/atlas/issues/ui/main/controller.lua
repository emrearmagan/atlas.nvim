local M = {}

local config = require("atlas.config")
local statusline = require("atlas.ui.statusline")
local status_spinner = require("atlas.ui.components.spinner")
local state = require("atlas.issues.state")
local layout = require("atlas.ui.layout")
local navigation = require("atlas.ui.navigation")
local info_popup = require("atlas.ui.popups.info")
local helper = require("atlas.issues.ui.main.helper")
local requests = require("atlas.core.requests")
local starred = require("atlas.core.starred")

local active_requests = requests.new()
local issue_reload_requests = requests.new()

local function render_if_active()
	if not layout.is_active() then
		return
	end

	local ui_main_state = require("atlas.ui.state")
	local provider = state.provider
	if provider == nil or ui_main_state.current_view ~= provider.id then
		return
	end

	require("atlas.issues.ui.main").render()
end

local refresh_status_spinner = status_spinner.create({
	interval_ms = 120,
	on_tick = function(frame)
		state.reload_spinner_frame = frame
		render_if_active()
	end,
})

local function reset_reload_state()
	refresh_status_spinner:stop()
	state.reloading_issue_keys = {}
	state.reload_spinner_frame = "⠋"
end

local function has_reloading_issues()
	for _, count in pairs(state.reloading_issue_keys or {}) do
		if (tonumber(count) or 0) > 0 then
			return true
		end
	end
	return false
end

---@param issue_key string
local function begin_issue_reload(issue_key)
	state.reloading_issue_keys = state.reloading_issue_keys or {}
	state.reloading_issue_keys[issue_key] = (tonumber(state.reloading_issue_keys[issue_key]) or 0) + 1

	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end

	state.reload_spinner_frame = refresh_status_spinner:current_frame()
	render_if_active()
end

---@param issue_key string
local function end_issue_reload(issue_key)
	state.reloading_issue_keys = state.reloading_issue_keys or {}
	local next_count = (tonumber(state.reloading_issue_keys[issue_key]) or 0) - 1
	if next_count > 0 then
		state.reloading_issue_keys[issue_key] = next_count
	else
		state.reloading_issue_keys[issue_key] = nil
	end

	if not has_reloading_issues() then
		refresh_status_spinner:stop()
		state.reload_spinner_frame = "⠋"
	end

	render_if_active()
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()

	issue_reload_requests.cancel()
	issue_reload_requests = requests.new()
	reset_reload_state()
end

---@param provider IssuesProvider
---@param scope AtlasRequestScope
local function fetch_current_user(provider, scope)
	if state.current_user ~= nil then
		return
	end
	scope.run(function(done)
		return provider.capabilities.core.fetch_user(done)
	end, function(user, err)
		if err then
			statusline.notify("warn", string.format("Failed to fetch current user: %s", tostring(err)))
			return
		end
		state.current_user = user
		render_if_active()
		local panel = require("atlas.issues.ui.panel")
		if layout.is_active() and require("atlas.ui.state").current_view == provider.id and panel.is_open() then
			panel.render()
		end
	end)
end

---@return AtlasIssuesConfig
local function issues_config()
	return (config.options and config.options.issues) or {}
end

---@generic T
---@param items T[]
---@param is_starred fun(item: T): boolean
---@return T[]
local function starred_first(items, is_starred)
	local first, rest = {}, {}
	for _, item in ipairs(items) do
		table.insert(is_starred(item) and first or rest, item)
	end
	vim.list_extend(first, rest)
	return first
end

---@param issues Issue[]
local function set_issues(issues)
	local saved_by_ref = {}
	local saved = starred.list("issues", state.provider.id) or {}
	for _, item in ipairs(saved) do
		saved_by_ref[item.ref] = true
	end

	for _, issue in ipairs(issues) do
		issue.is_starred = saved_by_ref[starred.ref(issue, state.provider.id)] == true
	end

	local sorted = starred_first(issues, function(issue)
		return issue.is_starred == true
	end)
	local groups = helper.build_issue_tree(sorted)
	groups = starred_first(groups, function(group)
		if group.issue.is_starred then
			return true
		end
		for _, child in ipairs(group.children) do
			if child.is_starred then
				return true
			end
		end
		return false
	end)

	state.issues = sorted
	state.issue_tree = groups
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
		state.is_loading = false
		state.error = "No issues views configured"
		statusline.notify("error", state.error)
		render_if_active()
		on_done()
		return
	end

	cancel_active_requests()
	if target_view._kind == "bookmarks" then
		if refresh_status_spinner:is_running() then
			refresh_status_spinner:stop()
		end
		state.is_loading = false
		state.error = nil
		state.issues = nil
		state.issue_tree = nil
		state.current_view = state.active_view
		state.line_map = {}
		render_if_active()
		on_done()
		return
	end

	local load_requests = active_requests
	fetch_current_user(provider, load_requests)

	state.is_loading = true
	state.error = nil
	state.issues = nil
	state.issue_tree = nil
	state.line_map = {}
	statusline.notify("loading", "Loading issues...")
	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end
	state.reload_spinner_frame = refresh_status_spinner:current_frame()

	render_if_active()

	local function finish_loading()
		state.is_loading = false
		if not has_reloading_issues() then
			refresh_status_spinner:stop()
		end
	end

	local function finalize_fetch_failure(err, issues)
		finish_loading()
		state.current_view = state.active_view

		if #issues > 0 then
			state.error = nil
			set_issues(issues)
			statusline.notify("warn", string.format("Stopped at %d issues: %s", #issues, tostring(err)))
		else
			state.error = tostring(err)
			state.issues = nil
			state.issue_tree = nil
			statusline.notify("error", string.format("Failed to fetch issues: %s", tostring(err)))
		end

		render_if_active()
		on_done()
	end

	local function finalize_fetch_success(issues)
		state.current_view = state.active_view
		state.error = nil
		set_issues(issues)
		finish_loading()

		statusline.notify("success", string.format("Loaded %d issues", #issues), 1200)
		render_if_active()
		on_done()
	end

	local configured_max = tonumber(issues_config().max_results)
	local max_results = (configured_max and configured_max > 0) and math.floor(configured_max) or 100

	local function fetch_page(next_page_token, issues)
		issues = issues or {}
		local remaining = max_results - #issues
		if remaining <= 0 then
			finalize_fetch_success(issues)
			return
		end

		load_requests.run(function(done)
			return provider.capabilities.core.fetch_issues(target_view, {
				force_load = opts.force_load == true,
				next_page_token = next_page_token,
				max_results = remaining,
				layout = target_view.layout or "plain",
			}, done)
		end, function(page_issues, next_token, is_last, err)
			if err ~= nil then
				finalize_fetch_failure(err, issues)
				return
			end

			for _, issue in ipairs(page_issues or {}) do
				if #issues >= max_results then
					break
				end
				table.insert(issues, issue)
			end

			state.current_view = state.active_view
			state.error = nil
			set_issues(issues)
			render_if_active()

			if #issues >= max_results then
				finalize_fetch_success(issues)
				return
			end

			if is_last ~= true and next_token ~= nil and next_token ~= "" then
				fetch_page(next_token, issues)
				return
			end

			finalize_fetch_success(issues)
		end)
	end

	fetch_page(nil, {})
end

---@param view IssuesViewConfig
---@param force_load boolean
---@param on_done fun()|nil
local function load_bookmark(view, force_load, on_done)
	local provider = state.provider
	if provider == nil then
		return
	end

	cancel_active_requests()
	if view._kind == "starred" then
		state.is_loading = false
		state.error = nil
		state.current_view = view
		local saved, err = starred.list("issues", provider.id)
		if err then
			state.error = err
			set_issues({})
		elseif #saved == 0 then
			if layout.win_id("detail") then
				layout.toggle_detail()
			end
			if next(state.active_view._bookmarks) == nil then
				M.switch_view(require("atlas.ui.shared.bookmarks_view").views(provider, "issues")[1])
				return
			end
			state.current_view = state.active_view
			state.issues = nil
			state.issue_tree = nil
		else
			local issues = {}
			for _, item in ipairs(saved) do
				item.item.title = item.item.title or item.item.summary or ""
				item.item.summary = nil
				item.item.is_starred = true
				table.insert(issues, item.item)
			end
			state.issues = issues
			state.issue_tree = helper.build_issue_tree(issues)
		end
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	local load_requests = active_requests
	fetch_current_user(provider, load_requests)
	state.is_loading = true
	state.error = nil
	state.issues = nil
	state.issue_tree = nil
	state.current_view = view
	statusline.notify("loading", "Running query...")
	render_if_active()

	load_requests.run(function(done)
		return provider.capabilities.core.fetch_issues(view, {
			force_load = force_load,
			max_results = tonumber((config.options and config.options.issues or {}).max_results) or 100,
			layout = view.layout,
		}, done)
	end, function(issues, _, _, err)
		state.is_loading = false
		if err then
			state.error = tostring(err)
			statusline.notify("error", string.format("Query failed: %s", state.error))
		else
			state.error = nil
			set_issues(issues or {})
			statusline.notify("success", string.format("Loaded %d issues", #(issues or {})), 1200)
		end
		render_if_active()
		if on_done then
			on_done()
		end
	end)
end

---@param on_done fun()|nil
---@param focus_issue_key string|nil
function M.refresh_current_view(on_done, focus_issue_key)
	local provider = state.provider
	local refresh = provider and provider.capabilities.core.refresh
	if refresh then
		refresh()
	end
	local current_view = state.current_view
	local bookmark_active = state.active_view
		and state.active_view._kind == "bookmarks"
		and current_view
		and current_view._kind ~= "bookmarks"
	if bookmark_active and focus_issue_key == nil then
		local item = navigation.current_item()
		if item and item.kind == "issue" and item._issue then
			focus_issue_key = item._issue.key
		end
	end

	local function finish()
		local focused = bookmark_active and focus_issue_key == nil
		if focus_issue_key ~= nil then
			focused = navigation.focus_item(function(item)
				return item.kind == "issue" and item._issue and item._issue.key == focus_issue_key
			end)
		end
		if not focused then
			navigation.focus_first_item()
		end
		local item = navigation.current_item()
		local panel = require("atlas.issues.ui.panel")
		if panel.is_open() then
			if focus_issue_key and not focused then
				panel.close()
			elseif type(item) == "table" and item.kind == "issue" and item._issue then
				panel.on_select(item._issue, { force_refresh = true })
			else
				panel.close()
			end
		end
		if on_done ~= nil then
			on_done()
		end
	end

	if bookmark_active then
		load_bookmark(current_view, true, finish)
	else
		load_active_view({ force_load = true }, finish)
	end
end

---@param view IssuesViewConfig|nil
function M.switch_view(view)
	state.active_view = view
	load_active_view({ force_load = false }, function()
		navigation.focus_first_item()
	end)
end

---@param name string
---@param value any
function M.run_bookmark(name, value)
	local view = { name = name, layout = "compact" }
	if type(value) == "string" then
		view.search = value
	elseif type(value) == "table" then
		for k, v in pairs(value) do
			view[k] = v
		end
	end

	load_bookmark(view, false)
end

---@param issue Issue|nil
function M.toggle_issue_star(issue)
	if issue == nil then
		statusline.notify("warn", "No issue selected")
		return
	end

	local now_starred, err = starred.toggle(issue, state.provider.id)
	if now_starred == nil then
		statusline.notify("error", tostring(err or "Unable to update starred issue"))
		return
	end

	local starred_view = state.current_view and state.current_view._kind == "starred"
	statusline.notify("success", now_starred and "Issue starred" or "Issue unstarred", 1200)
	if starred_view then
		load_bookmark(state.current_view, false)
		return
	end
	set_issues(state.issues or {})
	render_if_active()
end

---@param source_buf integer|nil
function M.show_issue_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		statusline.notify("warn", "No issue selected")
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	if issue == nil then
		statusline.notify("warn", "Issue payload missing on line")
		return
	end

	local renderer = require("atlas.issues.ui.main.renderer")
	local lines, highlights = renderer.issue_popup_content(issue)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

---@param result IssuesActionResult|nil
function M.apply_action_result(result)
	if result == nil or result.issue_key == nil or result.issue_key == "" then
		return
	end

	for _, issue in ipairs(state.issues or {}) do
		if issue.key == result.issue_key and not result.removed then
			M.refresh_issue(result.issue_key)
			return
		end
	end

	M.refresh_current_view(nil, result.issue_key)
end

---@param issue Issue|string|nil
---@param on_done fun()|nil
function M.refresh_issue(issue, on_done)
	on_done = on_done or function() end

	local issue_key = type(issue) == "table" and tostring(issue.key or "") or (type(issue) == "string" and issue or "")
	if issue_key == "" then
		statusline.notify("warn", "Issue key missing")
		on_done()
		return
	end
	if state.is_issue_reloading(issue_key) then
		on_done()
		return
	end

	local provider = state.provider
	if provider == nil then
		on_done()
		return
	end

	statusline.notify("loading", string.format("Reloading %s...", issue_key))
	begin_issue_reload(issue_key)

	local active_view = type(state.active_view) == "table" and state.active_view or {}
	issue_reload_requests.run(function(done)
		return provider.capabilities.core.fetch_issue(
			issue_key,
			{ force_load = true, layout = active_view.layout or "plain" },
			done
		)
	end, function(fetched_issue, err)
		if err ~= nil or fetched_issue == nil then
			end_issue_reload(issue_key)
			statusline.notify("error", tostring(err or "Failed to reload issue"))
			on_done()
			return
		end

		local issues = state.issues or {}
		local replaced = false
		for i, existing in ipairs(issues) do
			if type(existing) == "table" and existing.key == issue_key then
				issues[i] = fetched_issue
				replaced = true
				break
			end
		end

		if not replaced then
			table.insert(issues, fetched_issue)
		end

		set_issues(issues)
		local snapshot_err
		if fetched_issue.is_starred then
			local _, err = starred.add(fetched_issue, state.provider.id)
			snapshot_err = err
		end
		end_issue_reload(issue_key)

		local panel = require("atlas.issues.ui.panel")
		local panel_issue = require("atlas.issues.ui.panel.issue.state").current_issue
		if panel.is_open() and panel_issue and tostring(panel_issue.key or "") == issue_key then
			panel.on_select(fetched_issue, { force_refresh = true, details = fetched_issue })
		end

		if snapshot_err then
			statusline.notify("warn", snapshot_err)
		else
			statusline.notify("success", string.format("Reloaded %s", issue_key), 1200)
		end
		on_done()
	end)
end

function M.toggle_current_issue_collapsed()
	if state.toggle_current_issue_collapsed() ~= true then
		return
	end
	render_if_active()
end

function M.toggle_all_issues_collapsed()
	if state.toggle_all_issues_collapsed() ~= true then
		return
	end
	render_if_active()
end

---@param on_done fun()|nil
function M.refresh_current_issue(on_done)
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		statusline.notify("warn", "No issue selected")
		if on_done then
			on_done()
		end
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	M.refresh_issue(issue, on_done)
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
