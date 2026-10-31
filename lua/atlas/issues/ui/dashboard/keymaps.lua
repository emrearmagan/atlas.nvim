local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local action_runner = require("atlas.core.actions")
local state = require("atlas.issues.state")
local window = require("atlas.issues.ui.dashboard.window")
local navigation = require("atlas.issues.ui.dashboard.navigation")
local controller = require("atlas.issues.ui.dashboard.controller")
local layouts = require("atlas.issues.ui.layouts")
local help = require("atlas.ui.popups.help")
local registrations = {}

---@return Issue|nil
local function selected_issue()
	local node = navigation.current_item()
	return node and node.issue
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
	local dashboard = require("atlas.issues.ui.dashboard")
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
---@param views IssuesViewConfig[]
function M.register(buf, views)
	local provider = assert(state.provider)
	local capabilities = provider.capabilities
	local function context(issue)
		return { provider = provider, issue = issue, current_user = state.current_user }
	end

	local function run_with_issue(action_id, on_done)
		return function()
			local issue = selected_issue()
			if issue == nil then
				notify.warn("No issue selected")
				return
			end
			actions.run(action_id, context(issue), on_done)
		end
	end

	local function supports(action_id)
		return action_runner.find(capabilities.actions, action_id) ~= nil
	end

	local items = {}
	local filters = {}
	utils.insert_if(
		items,
		item("ui.cycle_layout", {
			desc = "Cycle layout",
			index = 19,
			callback = controller.cycle_layout,
		})
	)

	if layouts.resolve("board", provider.id) == "board" then
		utils.insert_if(
			items,
			item("ui.previous_column", {
				desc = "Previous status column (board)",
				callback = function()
					navigation.move_column(-vim.v.count1)
				end,
			})
		)
		utils.insert_if(
			items,
			item("ui.next_column", {
				desc = "Next status column (board)",
				callback = function()
					navigation.move_column(vim.v.count1)
				end,
			})
		)
	end

	for _, view in ipairs(views) do
		if view ~= state.bookmarks.tab and view.key ~= nil and view.key ~= "" then
			table.insert(items, {
				key = view.key,
				desc = string.format("Switch to %s", view.name),
				hidden = true,
				callback = function()
					controller.switch_view(view)
				end,
			})
		end
	end

	local bookmark_view = state.bookmarks.tab --[[@as IssuesViewConfig]]
	table.insert(items, {
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
		items,
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

	if capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open issue actions",
				index = 1,
				callback = function()
					local issue = selected_issue()
					actions.open(context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	if actions.is_available("create_issue", context(nil)) then
		utils.insert_if(
			items,
			item("issues.create_issue", {
				desc = "Create issue",
				index = 6,
				callback = function()
					local issue = selected_issue()
					actions.run("create_issue", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	if actions.is_available("search", context(nil)) then
		utils.insert_if(
			filters,
			item("ui.search", {
				desc = "Search issues",
				index = 1,
				callback = function()
					actions.run("search", context(nil), controller.apply_action_result)
				end,
			})
		)
	end

	if actions.is_available("edit_search", context(nil)) then
		utils.insert_if(
			filters,
			item("ui.edit_search", {
				desc = "Edit current search",
				index = 2,
				callback = function()
					actions.run("edit_search", context(nil), controller.apply_action_result)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show issue details",
			index = 3,
			callback = function()
				controller.show_issue_details(buf)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_star", {
			desc = "Star or unstar issue",
			index = 30,
			callback = function()
				controller.toggle_issue_star(selected_issue())
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Reload selected issue",
			index = 80,
			callback = controller.refresh_current_issue,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			index = 81,
			callback = controller.refresh_view,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_fold", {
			desc = "Toggle issue children",
			index = 17,
			callback = controller.toggle_current_issue_collapsed,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_all_folds", {
			desc = "Toggle all issue children",
			index = 18,
			callback = controller.toggle_all_issues_collapsed,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_id", {
			desc = "Copy issue key",
			index = 8,
			callback = run_with_issue("copy_issue_key"),
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_url", {
			desc = "Copy issue URL",
			index = 9,
			callback = run_with_issue("copy_issue_url"),
		})
	)

	if supports("transition") then
		utils.insert_if(
			items,
			item("issues.transition_issue", {
				desc = "Transition issue",
				index = 21,
				callback = run_with_issue("transition", controller.apply_action_result),
			})
		)
	end

	if supports("assign") then
		utils.insert_if(
			items,
			item("issues.change_assignee", {
				desc = "Change assignee",
				index = 22,
				callback = run_with_issue("assign", controller.apply_action_result),
			})
		)
	end

	if supports("reporter") then
		utils.insert_if(
			items,
			item("issues.change_reporter", {
				desc = "Change reporter",
				index = 23,
				callback = run_with_issue("reporter", controller.apply_action_result),
			})
		)
	end

	if supports("edit_issue") then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
				desc = "Edit issue",
				index = 5,
				callback = run_with_issue("edit_issue", controller.apply_action_result),
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open issue in browser",
			index = 7,
			callback = run_with_issue("browse_issue"),
		})
	)

	utils.insert_if(
		items,
		item("ui.open_references", {
			desc = "Open references",
			index = 11,
			callback = function()
				local issue = selected_issue()
				if issue == nil then
					notify.warn("No issue selected")
					return
				end
				require("atlas.ui.links").select(provider, issue, "issue")
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_page", {
			desc = "Previous page",
			index = 15,
			callback = controller.previous_page,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_page", {
			desc = "Next page",
			index = 16,
			callback = controller.next_page,
		})
	)

	local custom = resolver.custom_items("issues", function(callback)
		local issue = selected_issue()
		return callback(context(issue), controller.apply_action_result)
	end)

	M.remove(buf)
	registrations[buf] = {
		{ group = "General", items = dashboard_items(buf), index = 210 },
		{ group = "General", items = items, index = 1 },
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
	if registered then
		for _, registration in ipairs(registered) do
			help.remove(registration.group, registration.items, { buffer = buf })
		end
		registrations[buf] = nil
	end
end

return M
