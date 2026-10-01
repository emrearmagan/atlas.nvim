local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")
local controller = require("atlas.pulls.ui.dashboard.controller")
local registrations = {}

---@return PullRequest|nil, AtlasRepository|nil
local function selected_pr()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil, nil
	end
	if (node.kind == "pr" or node.kind == "pr_meta") and type(node.pr) == "table" then
		return node.pr, node.repo
	end
	return nil, nil
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
---@param views AtlasPullsViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	M.remove(buf)
	local state = require("atlas.pulls.state")
	local provider_name = state.provider and state.provider.name or "Pulls"
	---@param id AtlasPullActionId
	---@param needs_pr boolean
	local function run_action(id, needs_pr)
		local pr = selected_pr()

		if needs_pr and not pr then
			notify.warn("No PR selected")
			return
		end
		if state.provider then
			actions.run(id, {
				provider = state.provider,
				pr = pr,
				current_user = state.current_user,
				buf = buf,
			}, function(result)
				if pr ~= nil and result ~= nil and result.changed_pr then
					controller.refresh_pr(pr)
				end
			end)
		end
	end

	local items = {}

	for _, view in ipairs(views) do
		if view ~= state.bookmarks.tab and view.key ~= nil and view.key ~= "" then
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

	for index, status in ipairs(state.available_states) do
		local value = status
		utils.insert_if(
			items,
			item("pulls.filters." .. value, {
				desc = string.format("Toggle %s filter", value),
				index = 40 + index,
				callback = function()
					controller.toggle_status_filter(value)
				end,
			})
		)
	end

	if state.provider then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open PR actions",
				index = 1,
				callback = function()
					local pr = selected_pr()
					if state.provider then
						actions.open({
							provider = state.provider,
							pr = pr,
							current_user = state.current_user,
							buf = buf,
						}, function(result)
							if pr ~= nil and result ~= nil and result.changed_pr then
								controller.refresh_pr(pr)
							end
						end)
					end
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open PR in browser",
			index = 5,
			opts = { nowait = true },
			callback = function()
				run_action("open_in_browser", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_url", {
			desc = "Copy PR URL",
			index = 6,
			opts = { nowait = true },
			callback = function()
				run_action("copy_url", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_id", {
			desc = "Copy PR ID",
			index = 7,
			opts = { nowait = true },
			callback = function()
				run_action("copy_id", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show PR details",
			index = 3,
			opts = { nowait = true },
			callback = function()
				controller.show_pr_details(buf)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_star", {
			desc = "Star or unstar PR",
			index = 21,
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
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			index = 4,
			opts = { nowait = true },
			callback = function()
				run_action("open_diff", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.checkout", {
			desc = "Checkout PR branch",
			index = 20,
			opts = { nowait = true },
			callback = function()
				run_action("checkout", true)
			end,
		})
	)

	local search_available = state.provider
		and actions.is_available("search", {
			provider = state.provider,
			current_user = state.current_user,
			buf = buf,
		})

	if search_available then
		utils.insert_if(
			items,
			item("ui.search", {
				desc = "Search",
				index = 30,
				callback = function()
					run_action("search", false)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.edit_search", {
			desc = "Edit Current Search",
			index = 31,
			callback = function()
				run_action("edit_search", false)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Refetch selected PR",
			index = 60,
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
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			index = 61,
			callback = controller.refresh_view,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_page", {
			desc = "Previous page",
			index = 10,
			callback = controller.previous_page,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_page", {
			desc = "Next page",
			index = 11,
			callback = controller.next_page,
		})
	)

	vim.list_extend(
		items,
		resolver.custom_items("pulls", function(callback)
			local pr = selected_pr()
			if state.provider then
				return callback({
					provider = state.provider,
					pr = pr,
					current_user = state.current_user,
					buf = buf,
				}, function(result)
					if pr and result and result.changed_pr then
						controller.refresh_pr(pr)
					end
				end)
			end
		end)
	)
	help.register(provider_name, items, { index = 220, buffer = buf })

	local general = {}
	utils.insert_if(
		general,
		item("pulls.open_repository", {
			desc = "Open repository browser",
			index = 40,
			opts = { nowait = true, silent = true },
			callback = function()
				local node = require("atlas.ui.navigation").current_item()
				local repo = type(node) == "table" and node.repo or nil
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
	help.register("General", general, { buffer = buf })
	registrations[buf] = {
		{ group = provider_name, items = items },
		{ group = "General", items = general },
	}
end

---@param buf integer
function M.remove(buf)
	local registered = registrations[buf]
	if registered == nil then
		return
	end
	local help = require("atlas.ui.popups.help")
	for _, registration in ipairs(registered) do
		help.remove(registration.group, registration.items, { buffer = buf })
	end
	registrations[buf] = nil
end

return M
