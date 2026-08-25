local M = {}

local config = require("atlas.config")
local notify = require("atlas.core.notify")
local status_spinner = require("atlas.ui.components.spinner")
local state = require("atlas.issues.state")
local dashboard_host = require("atlas.ui.dashboard")
local navigation = require("atlas.ui.navigation")
local info_popup = require("atlas.ui.popups.info")
local requests = require("atlas.core.requests")
local starred = require("atlas.core.starred")
local bookmarks = require("atlas.ui.shared.bookmarks")

local active_requests = requests.new()
local issue_reload_requests = requests.new()

local function render_if_active()
	local provider = state.provider
	if provider == nil or not dashboard_host.is_active("issues", provider.id) then
		return
	end

	require("atlas.issues.ui.dashboard").render()
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

---@param issue_key string
local function begin_issue_reload(issue_key)
	state.reloading_issue_keys[issue_key] = true

	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end

	state.reload_spinner_frame = refresh_status_spinner:current_frame()
	render_if_active()
end

---@param issue_key string
local function end_issue_reload(issue_key)
	state.reloading_issue_keys[issue_key] = nil

	if next(state.reloading_issue_keys) == nil then
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
			notify.warn(string.format("Failed to fetch current user: %s", tostring(err)))
			return
		end
		state.current_user = user
		render_if_active()
	end)
end

---@return AtlasIssuesConfig
local function issues_config()
	return (config.options and config.options.issues) or {}
end

---@param view IssuesViewConfig
---@return boolean
local function relationships_enabled(view)
	return view.layout ~= "compact" and issues_config().with_relationships ~= false
end

---@param issues Issue[]
---@return IssueRef[]
local function missing_parent_refs(issues)
	local existing = {}
	for _, issue in ipairs(issues) do
		existing[issue.key] = true
	end

	local refs = {}
	local seen = {}
	for _, issue in ipairs(issues) do
		local parent = issue.parent
		local key = parent and parent.key
		if key and not existing[key] and not seen[key] then
			seen[key] = true
			table.insert(refs, parent)
		end
	end
	return refs
end

---@param issues Issue[]
---@param additions Issue[]
---@return Issue[]
local function merge_issues(issues, additions)
	local existing = {}
	for _, issue in ipairs(issues) do
		existing[issue.key] = true
	end

	for _, issue in ipairs(additions) do
		if not existing[issue.key] then
			existing[issue.key] = true
			table.insert(issues, issue)
		end
	end
	return issues
end

---@param items AtlasStarredItem[]
local function cache_starred_items(items)
	state.starred_items = items
	state.views = bookmarks.views(state.provider.id, "issues", state.provider_views, items)
end

---@param issues Issue[]
---@return Issue[]
local function mark_starred(issues)
	local saved_by_ref = {}
	for _, item in ipairs(state.starred_items) do
		saved_by_ref[item.ref] = true
	end
	for _, issue in ipairs(issues) do
		issue.is_starred = saved_by_ref[starred.ref(issue, state.provider.id)] == true
	end
	return issues
end

---@param issue Issue
---@return string|nil
local function save_starred_issue(issue)
	if not issue.is_starred then
		return nil
	end
	local _, err = starred.add(issue, state.provider.id)
	return err
end

---@param updated Issue
---@return boolean, string|nil
local function replace_issue(updated)
	local issues = state.issues
	for index, current in ipairs(issues) do
		if current.key == updated.key then
			issues[index] = updated
			state.set_issues(mark_starred(issues))
			return true, save_starred_issue(updated)
		end
	end
	return false, nil
end

---@param provider IssuesProvider
---@param view IssuesViewConfig
---@param issues Issue[]
---@param force_load boolean
---@param scope AtlasRequestScope
---@param on_done fun(issues: Issue[])
local function fetch_missing_parents(provider, view, issues, force_load, scope, on_done)
	local fetch = provider.capabilities.core.fetch_by_refs
	if not relationships_enabled(view) then
		on_done(issues)
		return
	end

	local refs = missing_parent_refs(issues)
	if #refs == 0 then
		on_done(issues)
		return
	end

	scope.run(function(done)
		return fetch(refs, { force_load = force_load }, done)
	end, function(parents, err)
		if err then
			notify.warn("Failed to fetch parent issues: " .. tostring(err))
			on_done(issues)
			return
		end
		on_done(merge_issues(issues, parents))
	end)
end

---@param view IssuesViewConfig
---@param force_load boolean
---@param on_done fun()|nil
local function load_query(view, force_load, on_done)
	on_done = on_done or function() end

	local provider = state.provider
	if provider == nil then
		on_done()
		return
	end

	cancel_active_requests()
	local load_requests = active_requests
	fetch_current_user(provider, load_requests)

	state.is_loading = true
	state.error = nil
	state.set_issues({})
	state.current_view = view
	local bookmark_query = state.active_view ~= nil and state.active_view._kind == "bookmarks"
	notify.loading(bookmark_query and "Running query..." or "Loading issues...")
	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end
	state.reload_spinner_frame = refresh_status_spinner:current_frame()

	render_if_active()

	local function finish_loading()
		state.is_loading = false
		if next(state.reloading_issue_keys) == nil then
			refresh_status_spinner:stop()
		end
	end

	local function finalize_fetch_failure(err, issues)
		finish_loading()

		if #issues > 0 then
			state.error = nil
			state.set_issues(mark_starred(issues))
			notify.warn(string.format("Stopped at %d issues: %s", #issues, tostring(err)))
		else
			state.error = tostring(err)
			state.set_issues({})
			local message = bookmark_query and "Query failed: %s" or "Failed to fetch issues: %s"
			notify.error(string.format(message, tostring(err)))
		end

		render_if_active()
		on_done()
	end

	local function finalize_fetch_success(issues)
		state.error = nil
		fetch_missing_parents(provider, view, issues, force_load, load_requests, function(enriched)
			state.set_issues(mark_starred(enriched))
			finish_loading()

			notify.success(string.format("Loaded %d issues", #enriched), { timeout = 1200 })
			render_if_active()
			on_done()
		end)
	end

	local configured_max = tonumber(issues_config().max_results)
	local max_results = (configured_max and configured_max > 0) and math.floor(configured_max) or 100

	local function fetch_page(next_page_token, issues)
		local remaining = max_results - #issues
		if remaining <= 0 then
			finalize_fetch_success(issues)
			return
		end

		load_requests.run(function(done)
			return provider.capabilities.core.fetch_issues(view, {
				force_load = force_load,
				next_page_token = next_page_token,
				max_results = remaining,
				layout = view.layout or "plain",
				with_relationships = relationships_enabled(view),
			}, done)
		end, function(page_issues, next_token, is_last, err)
			if err ~= nil then
				finalize_fetch_failure(err, issues)
				return
			end

			for _, issue in ipairs(page_issues) do
				if #issues >= max_results then
					break
				end
				table.insert(issues, issue)
			end

			state.error = nil
			state.set_issues(mark_starred(issues))
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

---@param force_load boolean
---@param on_done fun()|nil
local function load_active_view(force_load, on_done)
	local view = state.active_view
	if view == nil then
		state.is_loading = false
		state.error = "No issues views configured"
		notify.error(state.error)
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	if view._kind ~= "bookmarks" then
		load_query(view, force_load, on_done)
		return
	end

	cancel_active_requests()
	local provider = state.provider
	if provider ~= nil then
		fetch_current_user(provider, active_requests)
	end
	state.is_loading = false
	state.error = nil
	state.set_issues({})
	state.current_view = view
	render_if_active()
	if on_done then
		on_done()
	end
end

---@param view IssuesViewConfig
---@param force_load boolean
---@param on_done fun()|nil
local function load_bookmark(view, force_load, on_done)
	local provider = state.provider
	if provider == nil then
		return
	end

	if view._kind ~= "starred" then
		load_query(view, force_load, on_done)
		return
	end

	cancel_active_requests()
	fetch_current_user(provider, active_requests)
	state.is_loading = false
	state.error = nil
	state.current_view = view
	local saved, err = starred.list("issues", provider.id)
	if err then
		state.error = err
		state.set_issues({})
	elseif #saved == 0 then
		cache_starred_items({})
		local detail = require("atlas.issues.ui.detail")
		if detail.is_open() then
			detail.close()
		end
		if next(state.active_view._bookmarks) == nil then
			M.switch_view(state.provider_views[1])
			return
		end
		state.current_view = state.active_view
		state.set_issues({})
	else
		cache_starred_items(saved)
		local issues = {}
		for _, item in ipairs(saved) do
			table.insert(issues, item.item)
		end
		state.set_issues(mark_starred(issues))
	end
	render_if_active()
	if on_done then
		on_done()
	end
end

function M.refresh_current_view()
	local provider = state.provider
	local refresh = provider and provider.capabilities.core.refresh
	if refresh then
		refresh()
	end
	local selected = navigation.current_item()
	local selected_key = selected and selected.kind == "issue" and selected._issue and selected._issue.key or nil
	local current_view = state.current_view
	local bookmark_active = state.active_view
		and state.active_view._kind == "bookmarks"
		and current_view
		and current_view._kind ~= "bookmarks"

	local function finish()
		local focused = false
		if selected_key then
			focused = navigation.focus_item(function(item)
				return item.kind == "issue" and item._issue and item._issue.key == selected_key
			end)
		end
		if not focused then
			navigation.focus_first_item()
		end
		local item = navigation.current_item()
		local detail = require("atlas.issues.ui.detail")
		if detail.is_open() then
			if not (selected_key and not focused) and item and item.kind == "issue" and item._issue then
				detail.select(item._issue, { force_refresh = true })
			else
				detail.close()
			end
		end
	end

	if bookmark_active then
		load_bookmark(current_view, true, finish)
	else
		load_active_view(true, finish)
	end
end

---@param view IssuesViewConfig|nil
function M.switch_view(view)
	state.active_view = view
	load_active_view(false, function()
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
		notify.warn("No issue selected")
		return
	end

	local now_starred, err = starred.toggle(issue, state.provider.id)
	if now_starred == nil then
		notify.error(tostring(err or "Unable to update starred issue"))
		return
	end

	local starred_view = state.current_view and state.current_view._kind == "starred"
	notify.success(now_starred and "Issue starred" or "Issue unstarred", { timeout = 1200 })
	if starred_view then
		load_bookmark(state.current_view, false)
		return
	end
	local saved = starred.list("issues", state.provider.id) or {}
	cache_starred_items(saved)
	state.set_issues(mark_starred(state.issues))
	render_if_active()
end

---@param source_buf integer|nil
function M.show_issue_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		notify.warn("No issue selected")
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	if issue == nil then
		notify.warn("Issue payload missing on line")
		return
	end

	local lines, highlights = require("atlas.issues.ui.popup").content(issue)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

---@param issue Issue
local function refresh_issue(issue)
	local issue_key = issue.key
	if issue_key == "" then
		notify.warn("Issue key missing")
		return
	end
	if state.reloading_issue_keys[issue_key] then
		return
	end

	local provider = state.provider
	if provider == nil then
		return
	end

	notify.loading(string.format("Reloading %s...", issue_key))
	begin_issue_reload(issue_key)

	---@type IssueRef
	local ref = issue
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.refresh()
	end
	issue_reload_requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_load = true }, done)
	end, function(fetched_issues, err)
		local fetched_issue = fetched_issues[1]
		if err ~= nil or fetched_issue == nil then
			end_issue_reload(issue_key)
			notify.error(tostring(err or "Failed to reload issue"))
			return
		end
		if fetched_issue.parent == nil then
			fetched_issue.parent = issue.parent
		end

		local replaced, snapshot_err = replace_issue(fetched_issue)
		if not replaced then
			local issues = state.issues
			table.insert(issues, fetched_issue)
			state.set_issues(mark_starred(issues))
			snapshot_err = save_starred_issue(fetched_issue)
		end
		end_issue_reload(issue_key)

		if snapshot_err then
			notify.warn(snapshot_err)
		else
			notify.success(string.format("Reloaded %s", issue_key), { timeout = 1200 })
		end
	end)
end

---@param result IssuesActionResult|nil
function M.apply_action_result(result)
	if result == nil or result.issue_key == nil or result.issue_key == "" then
		return
	end

	local issue
	for _, candidate in ipairs(state.issues) do
		if candidate.key == result.issue_key then
			issue = candidate
			break
		end
	end
	if issue and not result.removed then
		refresh_issue(issue)
	else
		M.refresh_current_view()
	end
end

---@param issue Issue
---@return boolean, string|nil
function M.update_issue(issue)
	local updated, err = replace_issue(issue)
	if updated then
		render_if_active()
	end
	return updated, err
end

function M.toggle_current_issue_collapsed()
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" or type(node._issue) ~= "table" then
		return
	end
	if state.toggle_issue_collapsed(node._issue.key) then
		render_if_active()
	end
end

function M.toggle_all_issues_collapsed()
	if state.toggle_all_issues_collapsed() then
		render_if_active()
	end
end

function M.refresh_current_issue()
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		notify.warn("No issue selected")
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	if issue == nil then
		notify.warn("Issue payload missing on line")
		return
	end
	refresh_issue(issue)
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
