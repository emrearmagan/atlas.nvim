local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local registrations = {}

---@return Issue|nil
local function selected_issue()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil
	end
	if node.kind == "issue" and type(node._issue) == "table" then
		return node._issue
	end
	return nil
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
---@param views IssuesViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local state = require("atlas.issues.state")
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
		for _, action in ipairs((capabilities.actions and capabilities.actions.items) or {}) do
			if action.id == action_id then
				return true
			end
		end
		return false
	end

	local items = {}
	local filters = {}
	utils.insert_if(
		items,
		item("ui.previous_column", {
			desc = "Previous status column (board)",
			callback = function()
				local view = state.search_view()
				if view and view.layout == "board" then
					require("atlas.ui.navigation").move_column(-vim.v.count1)
				else
					vim.cmd("normal! " .. vim.v.count1 .. "h")
				end
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.next_column", {
			desc = "Next status column (board)",
			callback = function()
				local view = state.search_view()
				if view and view.layout == "board" then
					require("atlas.ui.navigation").move_column(vim.v.count1)
				else
					vim.cmd("normal! " .. vim.v.count1 .. "l")
				end
			end,
		})
	)

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

	local bookmark_view = state.bookmarks.tab
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
				local navigation = require("atlas.ui.navigation")
				local node = navigation.current_item()
				if type(node) == "table" and (node.kind == "bookmark" or node.kind == "starred") then
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
			opts = { nowait = true },
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
			opts = { nowait = true },
			callback = run_with_issue("copy_issue_key"),
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_url", {
			desc = "Copy issue URL",
			index = 9,
			opts = { nowait = true },
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
			opts = { nowait = true },
			callback = run_with_issue("browse_issue"),
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
		{ group = "General", items = items, index = 1 },
		{ group = "Filters", items = filters, index = 2 },
		{ group = "Custom", items = custom, index = 3 },
	}
	for _, registration in ipairs(registrations[buf]) do
		help.register(registration.group, registration.items, { index = registration.index, buffer = buf })
	end
end

---@param buf integer
function M.remove(buf)
	local registered = registrations[buf]
	if registered then
		local help = require("atlas.ui.popups.help")
		for _, registration in ipairs(registered) do
			help.remove(registration.group, registration.items, { buffer = buf })
		end
		registrations[buf] = nil
	end
end

return M
