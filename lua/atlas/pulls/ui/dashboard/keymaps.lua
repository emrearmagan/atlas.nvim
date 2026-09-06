local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")
local registrations = {}

---@return PullRequest|nil, PullsRepo|nil
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
					require("atlas.pulls.ui.dashboard.controller").refresh_pr(pr)
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
					local controller = require("atlas.pulls.ui.dashboard.controller")
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
			for _, view in ipairs(state.views) do
				if view == bookmark_view then
					require("atlas.pulls.ui.dashboard.controller").switch_view(view)
					return
				end
			end
		end,
	})

	utils.insert_if(
		items,
		item("ui.select", {
			desc = "Run bookmark",
			callback = function()
				local navigation = require("atlas.ui.navigation")
				local node = navigation.current_item()
				if type(node) == "table" and (node.kind == "bookmark" or node.kind == "starred") then
					require("atlas.pulls.ui.dashboard.controller").select_bookmark(node)
				end
			end,
		})
	)

	for _, status in ipairs(state.available_states) do
		local value = status
		utils.insert_if(
			items,
			item("pulls.filters." .. value, {
				desc = string.format("Toggle %s filter", value),
				callback = function()
					local controller = require("atlas.pulls.ui.dashboard.controller")
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
								require("atlas.pulls.ui.dashboard.controller").refresh_pr(pr)
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
			opts = { nowait = true },
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").show_pr_details(buf)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_star", {
			desc = "Star or unstar PR",
			callback = function()
				local pr, repo = selected_pr()
				if pr == nil or repo == nil then
					notify.warn("No PR selected")
					return
				end
				require("atlas.pulls.ui.dashboard.controller").toggle_star(pr, repo)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
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
				callback = function()
					run_action("search", false)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Refetch selected PR",
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					notify.warn("No PR selected")
					return
				end
				require("atlas.pulls.ui.dashboard.controller").refresh_pr(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").refresh_view()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_page", {
			desc = "Previous page",
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").previous_page()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_page", {
			desc = "Next page",
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").next_page()
			end,
		})
	)

	help.register(provider_name, items, { index = 220, buffer = buf })

	local general = {}
	utils.insert_if(
		general,
		item("pulls.toggle_repo_panel", {
			desc = "Open repo panel",
			opts = { nowait = true, silent = true },
			callback = function()
				local _, repo = selected_pr()
				if repo == nil then
					notify.warn("No repository selected")
					return
				end
				local repo_detail = require("atlas.pulls.ui.repo_detail")
				if repo_detail.is_open() then
					repo_detail.close()
					return
				end
				repo_detail.open(repo, {
					provider = require("atlas.pulls.state").provider,
				})
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
