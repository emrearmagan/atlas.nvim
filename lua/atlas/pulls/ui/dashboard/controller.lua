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

local active_requests = requests.new()
local pr_reload_requests = requests.new()

---@param pulls PullRequest[]
---@return PullRequest[]
local function mark_starred(pulls)
	local records = starred.list("pulls", state.provider.id)
	if records == nil then
		return pulls
	end

	local refs = {}
	for _, record in ipairs(records) do
		refs[record.ref] = true
	end

	for _, pr in ipairs(pulls) do
		pr.is_starred = refs[starred.ref(pr, state.provider.id)] == true
	end
	return pulls
end

---@param pr PullRequest
---@return boolean
local function focus_pull_request(pr)
	return navigation.focus_item(function(item)
		return item.kind == "pr"
			and item.pr
			and tostring(item.pr.id) == tostring(pr.id)
			and tostring(item.pr.repo_full_name) == tostring(pr.repo_full_name)
	end)
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
	local pulls = state.pulls or {}
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
	if not updated.is_starred then
		return true, nil
	end
	local _, err = starred.add(updated, state.provider.id, presentation.repo(updated))
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

---@return boolean
local function has_reloading_prs()
	for _, count in pairs(state.reloading_pr_keys or {}) do
		if (tonumber(count) or 0) > 0 then
			return true
		end
	end
	return false
end

local function sync_loading_spinner()
	if state.is_loading or has_reloading_prs() then
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
	local key = state.reload_key(repo_id, pr_id)
	state.reloading_pr_keys[key] = (tonumber(state.reloading_pr_keys[key]) or 0) + 1

	sync_loading_spinner()
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

	sync_loading_spinner()

	render_if_active()
end

local function reset_reload_state()
	stop_loading_spinner()
	state.reloading_pr_keys = {}
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()
	pr_reload_requests.cancel()
	pr_reload_requests = requests.new()
	reset_reload_state()
end

---@param view AtlasPullsViewConfig
---@param on_done fun()|nil
local function load_starred(view, on_done)
	cancel_active_requests()
	state.is_loading = false
	state.error = nil
	state.current_view = view

	local records, err = starred.list("pulls", state.provider.id)
	if records == nil then
		state.error = err
		state.pulls = {}
	else
		if #records == 0 then
			local detail = require("atlas.pulls.ui.detail")
			if detail.is_open() then
				detail.close()
			end
			local repo_detail = require("atlas.pulls.ui.repo_detail")
			if repo_detail.is_open() then
				repo_detail.close()
			end
			if next(state.active_view._bookmarks) == nil then
				M.switch_view(require("atlas.ui.shared.bookmarks_view").views(state.provider, "pulls")[1])
				return
			end
			state.current_view = state.active_view
			state.pulls = nil
		else
			local pulls = {}
			for _, record in ipairs(records) do
				record.item.is_starred = true
				table.insert(pulls, record.item)
			end
			state.pulls = pulls
		end
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
	local core = provider.capabilities.core

	local target_view = state.active_view
	if target_view == nil then
		notify.error("No active view selected")
		on_done()
		return
	end

	if target_view._kind == "bookmarks" then
		cancel_active_requests()
		state.is_loading = false
		state.error = nil
		state.pulls = nil
		state.current_view = state.active_view
		render_if_active()
		on_done()
		return
	end

	cancel_active_requests()
	local load_requests = active_requests

	state.is_loading = true
	state.error = nil
	sync_loading_spinner()
	notify.loading("Loading pull requests...")
	render_if_active()

	---@param pulls PullRequest[]
	---@param err string[]|string|nil
	local function finalize_fetch(pulls, err)
		state.is_loading = false
		sync_loading_spinner()
		state.current_view = state.active_view

		local first_err = nil
		if type(err) == "table" then
			first_err = err[1]
		elseif err ~= nil then
			first_err = err
		end

		local has_pulls = #pulls > 0

		if first_err ~= nil then
			if has_pulls then
				state.error = nil
				state.pulls = mark_starred(pulls)
				notify.warn(string.format("Some repositories failed: %s", tostring(first_err)))
			else
				state.error = tostring(first_err)
				state.pulls = {}
				notify.error(string.format("Failed to fetch pull requests: %s", tostring(first_err)))
			end
		else
			state.error = nil
			state.pulls = mark_starred(pulls)
			notify.success("Pull requests loaded", { timeout = 1200 })
		end

		render_if_active()
		on_done()
	end

	local function fetch_pull_requests()
		load_requests.run(function(done)
			return core.fetch_pullrequests(target_view, { force_load = opts.force_load == true }, done)
		end, finalize_fetch)
	end

	if state.current_user == nil then
		get_current_user(load_requests, function(user_err)
			if user_err then
				notify.warn(string.format("Failed to fetch current user: %s", tostring(user_err)))
			else
				render_if_active()
			end
			fetch_pull_requests()
		end)
	else
		fetch_pull_requests()
	end
end

---@param view AtlasPullsViewConfig
---@param force_load boolean
---@param on_done fun()|nil
local function load_bookmark(view, force_load, on_done)
	local provider = state.provider
	if provider == nil then
		return
	end
	if view._kind == "starred" then
		load_starred(view, on_done)
		return
	end

	cancel_active_requests()
	local load_requests = active_requests
	state.is_loading = true
	state.error = nil
	state.pulls = nil
	state.current_view = view
	sync_loading_spinner()
	notify.loading("Running query...")
	render_if_active()

	load_requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, { force_load = force_load }, done)
	end, function(pulls, err)
		state.is_loading = false
		sync_loading_spinner()
		local first_err = type(err) == "table" and err[1] or err
		if first_err and #pulls == 0 then
			state.error = tostring(first_err)
			state.pulls = {}
			notify.error(string.format("Query failed: %s", state.error))
		else
			state.error = nil
			state.pulls = mark_starred(pulls)
			if first_err then
				notify.warn(string.format("Some repositories failed: %s", tostring(first_err)))
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

---@param on_done fun()|nil
---@param focus_pr PullRequest|nil
function M.refresh_current_view(on_done, focus_pr)
	local current_view = state.current_view
	local bookmark_active = state.active_view
		and state.active_view._kind == "bookmarks"
		and current_view
		and current_view._kind ~= "bookmarks"
	if bookmark_active and focus_pr == nil then
		local item = navigation.current_item()
		if item and item.kind == "pr" then
			focus_pr = item.pr
		end
	end

	local function finish()
		local focused = bookmark_active and focus_pr == nil
		if focus_pr ~= nil then
			focused = focus_pull_request(focus_pr)
		end
		if not focused then
			navigation.focus_first_item()
		end
		local item = navigation.current_item()
		local detail = require("atlas.pulls.ui.detail")
		local repo_detail = require("atlas.pulls.ui.repo_detail")
		if detail.is_open() then
			if (focus_pr and not focused) or type(item) ~= "table" or item.kind ~= "pr" or not item.pr then
				detail.close()
			else
				detail.select(item.pr, { force_refresh = true })
			end
		elseif repo_detail.is_open() then
			if type(item) ~= "table" or item.kind ~= "pr" or not item.repo then
				repo_detail.close()
			else
				repo_detail.select(item.repo, { force_refresh = true })
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

---@param pr PullRequest
---@return boolean, string|nil
function M.update_pr(pr)
	local updated, err = replace_pr(pr)
	if updated then
		render_if_active()
	end
	return updated, err
end

---@param pr PullRequest|nil
---@param on_done fun()|nil
function M.refresh_pr(pr, on_done)
	on_done = on_done or function() end

	if pr == nil or pr.id == nil then
		notify.warn("No PR selected")
		on_done()
		return
	end

	local provider = state.provider
	local core = provider and provider.capabilities.core
	if core == nil or core.fetch_pullrequest == nil then
		notify.warn("Provider does not support single PR refresh")
		on_done()
		return
	end

	local pr_id = pr.id
	local repo_id = tostring(pr.repo_full_name or "")
	if state.is_pr_reloading(repo_id, pr_id) then
		on_done()
		return
	end

	notify.loading(string.format("Reloading PR #%s...", tostring(pr_id)))
	begin_pr_reload(repo_id, pr_id)

	pr_reload_requests.run(function(done)
		return core.fetch_pullrequest(pr, { force_load = true }, done)
	end, function(fetched_pr, err)
		if err ~= nil or fetched_pr == nil then
			end_pr_reload(repo_id, pr_id)
			notify.error(tostring(err or "Failed to reload PR"))
			on_done()
			return
		end

		local _, snapshot_err = replace_pr(fetched_pr)
		end_pr_reload(repo_id, pr_id)

		local detail_state = require("atlas.pulls.ui.detail.state")
		local detail_pr = detail_state.current_pr
		local detail = require("atlas.pulls.ui.detail")
		if
			detail.is_open()
			and detail_pr ~= nil
			and tostring(detail_pr.id) == tostring(pr_id)
			and tostring(detail_pr.repo_full_name) == repo_id
		then
			detail.select(fetched_pr, {
				force_refresh = true,
				details = fetched_pr,
			})
		end

		if snapshot_err then
			notify.warn(snapshot_err)
		else
			notify.success(string.format("Reloaded PR #%s", tostring(pr_id)), { timeout = 1200 })
		end
		on_done()
	end)
end

---@param source_buf integer|nil
function M.show_pr_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or (node.kind ~= "pr" and node.kind ~= "pr_meta") then
		notify.warn("No PR selected")
		return
	end

	local pr = node.pr
	if type(pr) ~= "table" then
		notify.warn("No PR selected")
		return
	end

	local lines, highlights = require("atlas.pulls.ui.popup").content(pr)
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
	notify.success(now_starred and "Pull request starred" or "Pull request unstarred", { timeout = 1200 })

	local current_view = state.current_view
	if current_view and current_view._kind == "starred" then
		load_starred(current_view)
		return
	end

	render_if_active()
end

---@param pr PullRequest|nil
---@param result PullsActionResult|nil
function M.apply_action_result(pr, result)
	if pr ~= nil and result ~= nil and result.changed_pr then
		M.refresh_pr(pr)
	end
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
		notify.warn("At least one status filter must remain active")
		return
	end

	state.status_filters[status] = not state.status_filters[status]
	load_active_view({ force_load = true }, function()
		navigation.focus_first_item()
	end)
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
