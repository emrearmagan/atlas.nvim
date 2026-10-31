local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")
local controller = require("atlas.pulls.ui.dashboard.controller")
local state = require("atlas.pulls.state")
local window = require("atlas.pulls.ui.dashboard.window")
local navigation = require("atlas.pulls.ui.dashboard.navigation")
local help = require("atlas.ui.popups.help")
local registrations = {}

---@return PullRequest|nil, AtlasRepository|nil
local function selected_pr()
	local node = navigation.current_item()
	if node and node.pr then
		return node.pr, node.repo
	end
end

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end

	map_item.key = #keys == 1 and keys[1] or keys
	return map_item
end

---@param buf integer
---@return table[]
local function dashboard_items(buf)
	local dashboard = require("atlas.pulls.ui.dashboard")
	local items = {}

	utils.insert_if(
		items,
		item("ui.next_item", {
			desc = "Next item",
			hidden = true,
			callback = function()
				navigation.move_cursor("down")
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.previous_item", {
			desc = "Previous item",
			hidden = true,
			callback = function()
				navigation.move_cursor("up")
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.first_item", {
			desc = "Go to first item",
			hidden = true,
			callback = function()
				navigation.focus_first_item()
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.last_item", {
			desc = "Go to last item",
			hidden = true,
			callback = function()
				navigation.focus_last_item()
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.help", {
			desc = "Toggle this help popup",
			index = 100,
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.close", {
			desc = "Close Atlas window",
			index = 101,
			callback = function()
				if not help.is_open() then
					window.close()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			index = 12,
			callback = dashboard.toggle_detail,
		})
	)
	utils.insert_if(
		items,
		item("ui.next_panel_tab", {
			desc = "Next panel tab",
			index = 11,
			callback = dashboard.next_detail_tab,
		})
	)
	utils.insert_if(
		items,
		item("ui.previous_panel_tab", {
			desc = "Previous panel tab",
			index = 10,
			callback = dashboard.prev_detail_tab,
		})
	)
	utils.insert_if(
		items,
		item("ui.notifications.open", {
			desc = "Open notifications",
			index = 20,
			callback = function()
				require("atlas.ui.notifications").open(state.provider, window.render)
			end,
		})
	)
	return items
end

---@param buf integer
---@param views AtlasPullsViewConfig[]
function M.register(buf, views)
	M.remove(buf)
	local function context(pr)
		return { provider = state.provider, pr = pr, current_user = state.current_user, buf = buf }
	end
	local function on_result(pr)
		return function(result)
			if pr ~= nil and result ~= nil and result.changed_pr then
				controller.refresh_pr(pr)
			end
		end
	end
	---@param id AtlasPullActionId
	---@param needs_pr boolean
	local function run_action(id, needs_pr)
		local pr = selected_pr()

		if needs_pr and not pr then
			notify.warn("No PR selected")
			return
		end
		if state.provider then
			actions.run(id, context(pr), on_result(pr))
		end
	end

	local general = {}
	local filters = {}

	for _, view in ipairs(views) do
		if view ~= state.bookmarks.tab and view.key ~= nil and view.key ~= "" then
			local v = view
			table.insert(general, {
				key = v.key,
				desc = string.format("Switch to %s", v.name),
				hidden = true,
				callback = function()
					controller.switch_view(v)
				end,
			})
		end
	end

	local bookmark_view = state.bookmarks.tab
	---@cast bookmark_view AtlasPullsViewConfig
	table.insert(general, {
		key = bookmark_view.key,
		desc = "Switch to bookmarks",
		hidden = true,
		callback = function()
			if next(state.bookmarks.items) ~= nil or #state.starred_items > 0 then
				controller.switch_view(bookmark_view)
			end
		end,
	})

	utils.insert_if(
		general,
		item("ui.select", {
			desc = "Run bookmark",
			index = 2,
			callback = function()
				local node = navigation.current_item()
				if node and (node.kind == "bookmark" or node.kind == "starred") then
					controller.select_bookmark(node)
				end
			end,
		})
	)

	for index, status in ipairs(state.available_states) do
		local value = status
		utils.insert_if(
			filters,
			item("pulls.filters." .. value, {
				desc = string.format("Toggle %s filter", value),
				index = 10 + index,
				callback = function()
					controller.toggle_status_filter(value)
				end,
			})
		)
	end

	if state.provider then
		utils.insert_if(
			general,
			item("ui.open_actions", {
				desc = "Open PR actions",
				index = 1,
				callback = function()
					local pr = selected_pr()
					if state.provider then
						actions.open(context(pr), on_result(pr))
					end
				end,
			})
		)
	end

	utils.insert_if(
		general,
		item("ui.open_in_browser", {
			desc = "Open PR in browser",
			index = 7,
			callback = function()
				run_action("open_in_browser", true)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.open_references", {
			desc = "Open references",
			index = 11,
			callback = function()
				local pr = selected_pr()
				if not pr then
					notify.warn("No PR selected")
					return
				end
				if state.provider then
					require("atlas.ui.links").select(state.provider, pr, "pr")
				end
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.copy_url", {
			desc = "Copy PR URL",
			index = 9,
			callback = function()
				run_action("copy_url", true)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.copy_id", {
			desc = "Copy PR ID",
			index = 8,
			callback = function()
				run_action("copy_id", true)
			end,
		})
	)

	utils.insert_if(
		general,
		item("pulls.edit_pr", {
			desc = "Edit PR",
			index = 5,
			callback = function()
				run_action("edit_pr", true)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.show_details", {
			desc = "Show PR details",
			index = 3,
			callback = function()
				controller.show_pr_details(buf)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.toggle_star", {
			desc = "Star or unstar PR",
			index = 30,
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					notify.warn("No PR selected")
					return
				end
				controller.toggle_star(pr)
			end,
		})
	)

	utils.insert_if(
		general,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			index = 4,
			callback = function()
				run_action("open_diff", true)
			end,
		})
	)

	utils.insert_if(
		general,
		item("pulls.checkout", {
			desc = "Checkout PR branch",
			index = 6,
			callback = function()
				run_action("checkout", true)
			end,
		})
	)

	local search_available = state.provider and actions.is_available("search", context(nil))

	if search_available then
		utils.insert_if(
			filters,
			item("ui.search", {
				desc = "Search",
				index = 1,
				callback = function()
					run_action("search", false)
				end,
			})
		)
	end

	utils.insert_if(
		filters,
		item("ui.edit_search", {
			desc = "Edit current search",
			index = 2,
			callback = function()
				run_action("edit_search", false)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.refresh", {
			desc = "Refetch selected PR",
			index = 80,
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					notify.warn("No PR selected")
					return
				end
				controller.refresh_pr(pr)
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			index = 81,
			callback = controller.refresh_view,
		})
	)

	utils.insert_if(
		general,
		item("ui.previous_page", {
			desc = "Previous page",
			index = 15,
			callback = controller.previous_page,
		})
	)

	utils.insert_if(
		general,
		item("ui.next_page", {
			desc = "Next page",
			index = 16,
			callback = controller.next_page,
		})
	)

	utils.insert_if(
		general,
		item("ui.cycle_layout", {
			desc = "Cycle layout",
			index = 19,
			callback = controller.cycle_layout,
		})
	)

	utils.insert_if(
		general,
		item("pulls.open_repository", {
			desc = "Open repository browser",
			index = 40,
			callback = function()
				local node = navigation.current_item()
				local repo = node and node.repo
				if repo == nil then
					notify.warn("No repository selected")
					return
				end
				if state.provider == nil then
					notify.warn("Repository provider unavailable")
					return
				end
				require("atlas.ui.repository").open(repo.full_name, state.provider)
			end,
		})
	)

	local custom = resolver.custom_items("pulls", function(callback)
		local pr = selected_pr()
		if state.provider then
			return callback(context(pr), function(result)
				if pr and result and result.changed_pr then
					controller.refresh_pr(pr)
				end
			end)
		end
	end)

	registrations[buf] = {
		{ group = "General", items = dashboard_items(buf), index = 210 },
		{ group = "General", items = general, index = 1 },
		{ group = "Filters", items = filters, index = 2 },
		{ group = "Custom", items = custom, index = 3 },
	}
	for _, registration in ipairs(registrations[buf]) do
		for _, map_item in ipairs(registration.items) do
			map_item.opts = vim.tbl_extend("force", { nowait = true }, map_item.opts or {})
		end
		help.register(registration.group, registration.items, { index = registration.index, buffer = buf })
	end
	navigation.attach(buf)
end

---@param buf integer
function M.remove(buf)
	local registered = registrations[buf]
	if registered == nil then
		return
	end
	for _, registration in ipairs(registered) do
		help.remove(registration.group, registration.items, { buffer = buf })
	end
	registrations[buf] = nil
end

return M
