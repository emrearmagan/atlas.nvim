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

---@param view IssuesViewConfig|nil
local function resolve_view(view)
	if view ~= nil then
		state.query = state.provider.resolve_search(view)
	else
		state.query = ""
	end
end

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
	state.is_loading = false
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
	state.views = bookmarks.views(state.provider_views, state.bookmarks, items)
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

local function update_current_page()
	local page = state.page_history[state.current_page]
	if page ~= nil then
		page.items = state.issues
	end
end

---@param updated Issue
---@return boolean, string|nil
local function replace_issue(updated)
	local issues = state.issues
	for index, current in ipairs(issues) do
		if current.key == updated.key then
			issues[index] = updated
			state.set_issues(mark_starred(issues))
			update_current_page()
			return true, save_starred_issue(updated)
		end
	end
	return false, nil
end

---@param provider IssuesProvider
---@param view IssuesViewConfig
---@param issues Issue[]
---@param force_refresh boolean
---@param scope AtlasRequestScope
---@param on_done fun(issues: Issue[])
local function fetch_missing_parents(provider, view, issues, force_refresh, scope, on_done)
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
		return fetch(refs, { force_refresh = force_refresh }, done)
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
---@param page_number integer
---@param cursor string|nil
---@param force_refresh boolean
---@param on_done fun()|nil
local function load_page(view, page_number, cursor, force_refresh, on_done)
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
	if page_number == 1 then
		state.set_issues({})
	end
	notify.loading("Loading issues...")
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

	load_requests.run(function(done)
		return provider.capabilities.core.fetch_issues(view, {
			force_refresh = force_refresh,
			pagelen = 50,
			cursor = cursor,
		}, done)
	end, function(page, err)
		if err ~= nil then
			finish_loading()
			if page_number == 1 then
				state.error = tostring(err)
				state.set_issues({})
			end
			notify.error(string.format("Failed to fetch issues: %s", tostring(err)))
			render_if_active()
			on_done()
			return
		end

		state.error = nil
		fetch_missing_parents(provider, view, page.items, force_refresh, load_requests, function(enriched)
			state.set_issues(mark_starred(enriched))
			page.items = state.issues
			state.current_page = page_number
			state.page_history[page_number] = page
			finish_loading()
			notify.success(string.format("Loaded %d issues", #enriched), { timeout = 1200 })
			render_if_active()
			on_done()
		end)
	end)
end

---@param on_done fun()|nil
local function load_starred(on_done)
	local provider = state.provider
	if provider == nil then
		return
	end

	cancel_active_requests()
	fetch_current_user(provider, active_requests)
	state.is_loading = false
	state.error = nil
	local saved, err = starred.list("issues", provider.id)
	if saved == nil then
		state.error = err
		state.set_issues({})
	elseif #saved == 0 then
		cache_starred_items({})
		state.bookmarks.selection = nil
		local detail = require("atlas.issues.ui.detail")
		if detail.is_open() then
			detail.close()
		end
		state.set_issues({})
		if next(state.bookmarks.items) == nil then
			M.switch_view(state.provider_views[1])
			return
		end
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

---@param force_refresh boolean
---@param on_done fun()|nil
local function load_view(force_refresh, on_done)
	state.current_page = 1
	state.page_history = {}
	if state.view == nil then
		state.is_loading = false
		state.error = "No issues views configured"
		notify.error(state.error)
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	local bookmark_state = state.bookmarks
	if bookmark_state ~= nil and state.view == bookmark_state.tab then
		local selection = bookmark_state.selection
		if selection == nil then
			cancel_active_requests()
			state.is_loading = false
			state.error = nil
			state.set_issues({})
			render_if_active()
			if on_done then
				on_done()
			end
			return
		end
		if selection.kind == "starred" then
			load_starred(on_done)
			return
		end
	end

	local view = state.search_view()
	if view ~= nil then
		load_page(view, 1, nil, force_refresh, on_done)
		return
	end
end

function M.next_page()
	local current = state.page_history[state.current_page]
	if current == nil or current.next_cursor == nil then
		return
	end

	local page_number = state.current_page + 1
	local cached = state.page_history[page_number]
	if cached ~= nil then
		state.current_page = page_number
		state.set_issues(cached.items)
		state.error = nil
		render_if_active()
		navigation.focus_first_item()
		return
	end

	local view = state.search_view()
	if view == nil then
		return
	end
	load_page(view, page_number, current.next_cursor, false, function()
		navigation.focus_first_item()
	end)
end

function M.previous_page()
	local page_number = state.current_page - 1
	local page = state.page_history[page_number]
	if page == nil then
		return
	end
	cancel_active_requests()
	state.current_page = page_number
	state.set_issues(page.items)
	state.error = nil
	render_if_active()
	navigation.focus_first_item()
end

function M.refresh_view()
	local provider = state.provider
	local refresh = provider and provider.capabilities.core.refresh
	if refresh then
		refresh()
	end
	local selected = navigation.current_item()
	local selected_bookmark = selected and (selected.kind == "bookmark" or selected.kind == "starred")
	local selected_key = selected and selected.kind == "issue" and selected._issue and selected._issue.key or nil
	local function finish()
		local focused = false
		if selected_key then
			focused = navigation.focus_item(function(item)
				return item.kind == "issue" and item._issue and item._issue.key == selected_key
			end)
		end
		if not focused and not selected_bookmark then
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

	load_view(true, finish)
end

---@param view IssuesViewConfig|nil
function M.switch_view(view)
	state.view = view
	state.bookmarks.selection = nil
	resolve_view(state.search_view())
	load_view(false, function()
		navigation.focus_first_item()
	end)
end

---@param bookmark AtlasBookmarkSelection
function M.select_bookmark(bookmark)
	state.bookmarks.selection = bookmark
	resolve_view(state.search_view())
	load_view(false)
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

	local selected = state.bookmarks and state.bookmarks.selection
	notify.success(now_starred and "Issue starred" or "Issue unstarred", { timeout = 1200 })
	if selected and selected.kind == "starred" then
		load_starred()
		return
	end
	local saved = starred.list("issues", state.provider.id) or {}
	cache_starred_items(saved)
	state.set_issues(mark_starred(state.issues))
	update_current_page()
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
	local page_number = state.current_page
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
		detail.refresh(issue)
	end
	issue_reload_requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
	end, function(fetched_issues, err)
		if state.current_page ~= page_number then
			end_issue_reload(issue_key)
			return
		end
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
			update_current_page()
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
		M.refresh_view()
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
