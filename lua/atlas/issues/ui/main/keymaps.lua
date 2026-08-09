local M = {}

local statusline = require("atlas.ui.statusline")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")

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

	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param buf integer
---@param views IssuesViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local controller = require("atlas.issues.ui.main.controller")
	local state = require("atlas.issues.state")
	local provider = assert(state.provider)
	local provider_name = provider.name
	local capabilities = provider.capabilities
	local function context(issue)
		return { provider = provider, issue = issue, current_user = state.current_user }
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

	for _, view in ipairs(views or {}) do
		if view.key ~= nil and view.key ~= "" then
			local v = view
			table.insert(items, {
				key = v.key,
				desc = string.format("Switch to %s", v.name),
				hidden = true,
				callback = function()
					controller.switch_view(v)
				end,
			})
		end
	end

	table.insert(items, {
		key = "<CR>",
		desc = "Run bookmark",
		callback = function()
			local navigation = require("atlas.ui.navigation")
			local node = navigation.current_item()
			if type(node) == "table" and node.kind == "bookmark" then
				controller.run_bookmark(node.name, node.value)
			end
		end,
	})

	if capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open issue actions",
				index = 1,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						statusline.notify("warn", "No issue selected")
						return
					end
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
				index = 2,
				callback = function()
					actions.run("create_issue", context(selected_issue()), controller.apply_action_result)
				end,
			})
		)
	end

	if actions.is_available("search", context(nil)) then
		utils.insert_if(
			items,
			item("ui.search", {
				desc = "Search issues",
				index = 3,
				callback = function()
					actions.run("search", context(nil), controller.apply_action_result)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show issue details",
			index = 4,
			opts = { nowait = true },
			callback = function()
				controller.show_issue_details(buf)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Reload selected issue",
			index = 5,
			callback = function()
				controller.refresh_current_issue()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			index = 6,
			callback = function()
				controller.refresh_current_view()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_fold", {
			desc = "Toggle issue children",
			index = 7,
			callback = function()
				controller.toggle_current_issue_collapsed()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_all_folds", {
			desc = "Toggle all issue children",
			index = 8,
			callback = function()
				controller.toggle_all_issues_collapsed()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_id", {
			desc = "Copy issue key",
			index = 9,
			opts = { nowait = true },
			callback = function()
				local issue = selected_issue()
				if issue == nil then
					statusline.notify("warn", "No issue selected")
					return
				end
				actions.run("copy_issue_key", context(issue))
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_url", {
			desc = "Copy issue URL",
			index = 9,
			opts = { nowait = true },
			callback = function()
				local issue = selected_issue()
				if issue == nil then
					statusline.notify("warn", "No issue selected")
					return
				end
				actions.run("copy_issue_url", context(issue))
			end,
		})
	)

	-- g* keys grouped together
	if supports("transition") then
		utils.insert_if(
			items,
			item("issues.transition_issue", {
				desc = "Transition issue",
				index = 10,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						statusline.notify("warn", "No issue selected")
						return
					end
					actions.run("transition", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	if supports("assign") then
		utils.insert_if(
			items,
			item("issues.change_assignee", {
				desc = "Change assignee",
				index = 11,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						statusline.notify("warn", "No issue selected")
						return
					end
					actions.run("assign", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	if supports("reporter") then
		utils.insert_if(
			items,
			item("issues.change_reporter", {
				desc = "Change reporter",
				index = 12,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						statusline.notify("warn", "No issue selected")
						return
					end
					actions.run("reporter", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	if supports("edit_issue") then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
				desc = "Edit issue",
				index = 13,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						statusline.notify("warn", "No issue selected")
						return
					end
					actions.run("edit_issue", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open issue in browser",
			index = 14,
			opts = { nowait = true },
			callback = function()
				local issue = selected_issue()
				if issue == nil then
					statusline.notify("warn", "No issue selected")
					return
				end
				actions.run("browse_issue", context(issue))
			end,
		})
	)

	M.remove(buf)
	help.register(provider_name, items, {
		index = 230,
		buffer = buf,
	})
end

---@param buf integer
function M.remove(buf)
	local help = require("atlas.ui.popups.help")
	local state = require("atlas.issues.state")
	local provider_name = state.provider and state.provider.name or "Issues"
	local items = {}

	utils.insert_if(items, item("ui.open_actions", { key = "" }))
	utils.insert_if(items, item("issues.transition_issue", { key = "" }))
	utils.insert_if(items, item("issues.change_assignee", { key = "" }))
	utils.insert_if(items, item("issues.change_reporter", { key = "" }))
	utils.insert_if(items, item("issues.edit_issue", { key = "" }))
	utils.insert_if(items, item("issues.create_issue", { key = "" }))
	utils.insert_if(items, item("ui.search", { key = "" }))
	utils.insert_if(items, item("ui.open_in_browser", { key = "" }))
	utils.insert_if(items, item("ui.copy_id", { key = "" }))
	utils.insert_if(items, item("ui.copy_url", { key = "" }))
	utils.insert_if(items, item("ui.refresh", { key = "" }))
	utils.insert_if(items, item("ui.refresh_view", { key = "" }))
	utils.insert_if(items, item("ui.show_details", { key = "" }))
	utils.insert_if(items, item("ui.toggle_fold", { key = "" }))
	utils.insert_if(items, item("ui.toggle_all_folds", { key = "" }))

	help.remove(provider_name, items, { buffer = buf })
end

return M
