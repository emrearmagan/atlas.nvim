local M = {}

local notify = require("atlas.core.notify")
local spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pulls.state")
local dashboard_host = require("atlas.ui.dashboard")
local presentation = require("atlas.pulls.ui.presentation")
local navigation = require("atlas.ui.navigation")
local info_popup = require("atlas.ui.popups.info")
local requests = require("atlas.core.requests")
local starred = require("atlas.core.starred")
local bookmarks = require("atlas.ui.shared.bookmarks")

local active_requests = requests.new()
local pr_reload_requests = requests.new()

---@param view AtlasPullsViewConfig|nil
local function resolve_view(view)
	if view ~= nil then
		state.query, view._states = state.provider.resolve_search(view)
	else
		state.query = ""
	end
end

---@param pulls PullRequest[]
---@return PullRequest[]
local function mark_starred(pulls)
	local refs = {}
	for _, record in ipairs(state.starred_items) do
		refs[record.ref] = true
	end

	for _, pr in ipairs(pulls) do
		pr.is_starred = refs[starred.ref(pr, state.provider.id)] == true
	end
	return pulls
end

local function render_if_active()
	local provider = state.provider
	if provider == nil or not dashboard_host.is_active("pulls", provider.id) then
		return
	end
	require("atlas.pulls.ui.dashboard").render()
end

---@param updated PullRequest
---@return boolean, string|nil
local function replace_pr(updated)
	local pulls = state.pulls
	local replaced = false
	for index, current in ipairs(pulls) do
		if
			tostring(current.id) == tostring(updated.id)
			and tostring(current.repo_full_name) == tostring(updated.repo_full_name)
		then
			pulls[index] = updated
			replaced = true
			break
		end
	end

	if not replaced then
		return false, nil
	end
	state.pulls = mark_starred(pulls)
	local page = state.page_history[state.current_page]
	if page ~= nil then
		page.items = state.pulls
	end
	if not updated.is_starred then
		return true, nil
	end
	local saved, err = starred.add(updated, state.provider.id, presentation.repo(updated))
	if saved ~= nil then
		local replaced_snapshot = false
		for index, record in ipairs(state.starred_items) do
			if record.ref == saved.ref then
				state.starred_items[index] = saved
				replaced_snapshot = true
				break
			end
		end
		if not replaced_snapshot then
			table.insert(state.starred_items, saved)
		end
	end
	return true, err
end

local loading_spinner = spinner.create({
	interval_ms = 120,
	on_tick = function(frame)
		state.reload_spinner_frame = frame
		render_if_active()
	end,
})

local function stop_loading_spinner()
	loading_spinner:stop()
	state.reload_spinner_frame = "⠋"
end

local function sync_loading_spinner()
	if state.is_loading or next(state.reloading_pr_keys) ~= nil then
		if not loading_spinner:is_running() then
			loading_spinner:start()
		end
		state.reload_spinner_frame = loading_spinner:current_frame()
	else
		stop_loading_spinner()
	end
end

---@param repo_id string
---@param pr_id string|number
local function begin_pr_reload(repo_id, pr_id)
	state.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] = true

	sync_loading_spinner()
	render_if_active()
end

---@param repo_id string
---@param pr_id string|number
local function end_pr_reload(repo_id, pr_id)
	state.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] = nil

	sync_loading_spinner()

	render_if_active()
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()
	pr_reload_requests.cancel()
	pr_reload_requests = requests.new()
	state.is_loading = false
	stop_loading_spinner()
	state.reloading_pr_keys = {}
end

---@param on_done fun()|nil
local function load_starred(on_done)
	state.is_loading = false
	state.error = nil

	local records, err = starred.list("pulls", state.provider.id)
	if records == nil then
		state.error = err
		state.pulls = {}
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	state.starred_items = records
	state.views = bookmarks.views(state.provider_views, state.bookmarks, records)
	if #records == 0 then
		state.bookmarks.selection = nil
		state.pulls = {}
		if next(state.bookmarks.items) == nil then
			M.switch_view(state.provider_views[1])
			return
		end
	else
		local pulls = {}
		for _, record in ipairs(records) do
			record.item.is_starred = true
			table.insert(pulls, record.item)
		end
		state.pulls = pulls
	end

	render_if_active()
	if on_done then
		on_done()
	end
end

---@param scope AtlasRequestScope
---@param on_done fun(err: string|nil)
local function get_current_user(scope, on_done)
	if state.current_user ~= nil then
		on_done(nil)
		return
	end
	local provider = state.provider
	if provider == nil then
		on_done("no provider")
		return
	end
	scope.run(function(done)
		return provider.capabilities.core.fetch_user(done)
	end, function(user, err)
		if err ~= nil then
			on_done(tostring(err))
			return
		end
		state.current_user = user
		on_done(nil)
	end)
end

---@param provider PullsProvider
---@param view AtlasPullsViewConfig
---@param page_number integer
---@param cursor table<string, string>|nil
---@param force_refresh boolean
---@param on_done fun()|nil
local function load_page(provider, view, page_number, cursor, force_refresh, on_done)
	local previous_page = state.current_page
	state.current_page = page_number
	state.is_loading = true
	state.error = nil
	sync_loading_spinner()
	notify.loading("Loading pull requests...")
	render_if_active()

	active_requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, {
			force_refresh = force_refresh,
			pagelen = 50,
			cursor = cursor,
		}, done)
	end, function(page, err)
		state.is_loading = false
		sync_loading_spinner()
		local first_err = err and err[1]
		local has_pulls = #page.items > 0
		if first_err ~= nil and not has_pulls then
			state.current_page = previous_page
			if page_number == 1 then
				state.error = tostring(first_err)
				state.pulls = {}
			end
			notify.error(string.format("Failed to fetch pull requests: %s", tostring(first_err)))
		else
			page.items = mark_starred(page.items)
			state.error = nil
			state.page_history[page_number] = page
			state.pulls = page.items
			if first_err ~= nil then
				notify.warn(string.format("Pull requests loaded with errors: %s", tostring(first_err)))
			else
				notify.success("Pull requests loaded", { timeout = 1200 })
			end
		end

		render_if_active()
		if on_done then
			on_done()
		end
	end)
end

---@param force_refresh boolean
---@param on_done fun()|nil
local function load_view(force_refresh, on_done)
	local view = state.search_view()
	local provider = state.provider
	if provider == nil then
		if on_done then
			on_done()
		end
		return
	end

	cancel_active_requests()
	state.current_page = 1
	state.page_history = {}
	if state.view == nil then
		state.is_loading = false
		state.error = "No pull request view configured"
		state.pulls = {}
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	local bookmark_state = state.bookmarks
	local bookmark_selection
	if bookmark_state ~= nil and state.view == bookmark_state.tab then
		bookmark_selection = bookmark_state.selection
		if bookmark_selection == nil then
			state.is_loading = false
			state.error = nil
			state.pulls = {}
			render_if_active()
			if on_done then
				on_done()
			end
			return
		end
	end

	local load_requests = active_requests
	if state.current_user == nil then
		get_current_user(load_requests, function(user_err)
			if user_err then
				notify.warn(string.format("Failed to fetch current user: %s", tostring(user_err)))
			else
				render_if_active()
			end
		end)
	end
	if bookmark_selection and bookmark_selection.kind == "starred" then
		load_starred(on_done)
		return
	end
	if view == nil then
		return
	end
	state.pulls = {}
	load_page(provider, view, 1, nil, force_refresh, on_done)
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
		state.pulls = cached.items
		state.error = nil
		render_if_active()
		navigation.focus_first_item()
		return
	end

	local provider = state.provider
	local view = state.search_view()
	if provider == nil or view == nil then
		return
	end
	cancel_active_requests()
	load_page(provider, view, page_number, current.next_cursor, false, function()
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
	state.pulls = page.items
	state.error = nil
	render_if_active()
	navigation.focus_first_item()
end

function M.refresh_view()
	local view = state.view
	if view == nil then
		return
	end

	local selected_item = navigation.current_item()
	local selected_bookmark = selected_item and (selected_item.kind == "bookmark" or selected_item.kind == "starred")
	local selected_pr = type(selected_item) == "table"
			and (selected_item.kind == "pr" or selected_item.kind == "pr_meta")
			and type(selected_item.pr) == "table"
			and selected_item.pr
		or nil
	local function finish()
		local focused = false
		if selected_pr ~= nil then
			focused = navigation.focus_item(function(item)
				return item.kind == "pr"
					and tostring(item.pr.id) == tostring(selected_pr.id)
					and item.pr.repo_full_name == selected_pr.repo_full_name
			end)
		end
		if not focused and not selected_bookmark then
			navigation.focus_first_item()
		end

		local detail = require("atlas.pulls.ui.detail")
		local repo_detail = require("atlas.pulls.ui.repo_detail")
		local item = navigation.current_item()
		if
			(selected_pr ~= nil and not focused)
			or type(item) ~= "table"
			or item.kind ~= "pr"
			or type(item.pr) ~= "table"
		then
			if detail.is_open() then
				detail.close()
			end
			if repo_detail.is_open() then
				repo_detail.close()
			end
			return
		end

		if detail.is_open() then
			detail.select(item.pr, { force_refresh = true })
		elseif repo_detail.is_open() then
			repo_detail.select(item.repo, { force_refresh = true })
		end
	end

	load_view(true, finish)
end

---@param pr PullRequest
function M.refresh_pr(pr)
	local provider = state.provider
	if provider == nil then
		return
	end
	local core = provider.capabilities.core

	local pr_id = pr.id
	local repo_id = pr.repo_full_name
	if state.is_pr_reloading(repo_id, pr_id) then
		return
	end

	notify.loading(string.format("Reloading PR #%s...", tostring(pr_id)))
	begin_pr_reload(repo_id, pr_id)
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		detail.refresh(pr)
	end

	pr_reload_requests.run(function(done)
		return core.fetch_by_refs({ pr }, { force_refresh = true }, done)
	end, function(fetched_prs, err)
		local fetched_pr = fetched_prs[1]
		if err ~= nil or fetched_pr == nil then
			end_pr_reload(repo_id, pr_id)
			notify.error(tostring(err or "Failed to reload PR"))
			return
		end

		local _, snapshot_err = replace_pr(fetched_pr)
		end_pr_reload(repo_id, pr_id)

		if snapshot_err then
			notify.warn(snapshot_err)
		else
			notify.success(string.format("Reloaded PR #%s", tostring(pr_id)), { timeout = 1200 })
		end
	end)
end

---@param source_buf integer|nil
function M.show_pr_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or (node.kind ~= "pr" and node.kind ~= "pr_meta") or type(node.pr) ~= "table" then
		notify.warn("No PR selected")
		return
	end

	local pr = node.pr
	local lines, highlights = require("atlas.pulls.ui.dashboard.popup").content(pr)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

---@param pr PullRequest
---@param repo PullsRepo
function M.toggle_star(pr, repo)
	local now_starred, err = starred.toggle(pr, state.provider.id, repo)
	if now_starred == nil then
		notify.error(err or "Unable to update starred pull request")
		return
	end

	pr.is_starred = now_starred
	local records = starred.list("pulls", state.provider.id)
	if records ~= nil then
		state.starred_items = records
		state.views = bookmarks.views(state.provider_views, state.bookmarks, records)
	end
	notify.success(now_starred and "Pull request starred" or "Pull request unstarred", { timeout = 1200 })

	local selection = state.bookmarks and state.bookmarks.selection
	if selection and selection.kind == "starred" then
		load_view(false)
		return
	end

	render_if_active()
end

---@param view AtlasPullsViewConfig|nil
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

---@param status string
function M.toggle_status_filter(status)
	local view = state.search_view()
	if view == nil then
		return
	end

	local states = state.selected_states()
	local selected = {}
	for _, value in ipairs(states) do
		selected[value] = true
	end
	if selected[status] and #states == 1 then
		notify.warn("At least one status filter must remain active")
		return
	end
	selected[status] = not selected[status]
	view._states = {}
	for _, value in ipairs(state.available_states) do
		if selected[value] then
			table.insert(view._states, value)
		end
	end
	resolve_view(view)
	M.refresh_view()
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
