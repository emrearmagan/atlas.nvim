local M = {}

local statusline = require("atlas.ui.statusline")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")

---@return PullRequest|nil, PullsRepo|nil
local function selected_pr()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil, nil
	end
	if node.kind == "pr" and type(node.pr) == "table" then
		return node.pr, node.repo
	end
	if node.kind == "pr_meta" and type(node.pr) == "table" then
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
	local state = require("atlas.pulls.state")
	local provider_name = state.provider and state.provider.name or "Pulls"
	---@param id AtlasPullActionId
	---@param needs_pr boolean
	local function run_action(id, needs_pr)
		local pr = selected_pr()

		if needs_pr and not pr then
			statusline.notify("warn", "No PR selected")
			return
		end
		if state.provider then
			actions.run(id, {
				provider = state.provider,
				pr = pr,
				current_user = state.current_user,
				buf = buf,
			}, function(result)
				require("atlas.pulls.ui.main.controller").apply_action_result(pr, result)
			end)
		end
	end

	local items = {}

	for _, view in ipairs(views or {}) do
		if view._kind ~= "bookmarks" and view.key ~= nil and view.key ~= "" then
			local v = view
			table.insert(items, {
				key = v.key,
				desc = string.format("Switch to %s", v.name),
				hidden = true,
				callback = function()
					local controller = require("atlas.pulls.ui.main.controller")
					controller.switch_view(v)
				end,
			})
		end
	end

	local bookmark_key = state.provider and require("atlas.ui.shared.bookmarks_view").key("pulls", state.provider.id)
	if bookmark_key then
		table.insert(items, {
			key = bookmark_key,
			desc = "Switch to bookmarks",
			hidden = true,
			callback = function()
				for _, view in ipairs(require("atlas.ui.shared.bookmarks_view").views(state.provider, "pulls")) do
					if view._kind == "bookmarks" then
						require("atlas.pulls.ui.main.controller").switch_view(view)
						return
					end
				end
			end,
		})
	end

	utils.insert_if(
		items,
		item("ui.select", {
			desc = "Run bookmark",
			callback = function()
				local navigation = require("atlas.ui.navigation")
				local node = navigation.current_item()
				if type(node) == "table" and node.kind == "bookmark" then
					require("atlas.pulls.ui.main.controller").run_bookmark(node.name, node.value)
				end
			end,
		})
	)

	local STATUS_TOGGLES = {
		{ status = "OPEN", action_id = "pulls.filters.open" },
		{ status = "MERGED", action_id = "pulls.filters.merged" },
		{ status = "DECLINED", action_id = "pulls.filters.declined" },
	}
	for _, sf in ipairs(STATUS_TOGGLES) do
		local s = sf
		utils.insert_if(
			items,
			item(s.action_id, {
				desc = string.format("Toggle %s filter", s.status:lower()),
				callback = function()
					local controller = require("atlas.pulls.ui.main.controller")
					controller.toggle_status_filter(s.status)
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
							require("atlas.pulls.ui.main.controller").apply_action_result(pr, result)
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
				require("atlas.pulls.ui.main.controller").show_pr_details(buf)
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
					statusline.notify("warn", "No PR selected")
					return
				end
				require("atlas.pulls.ui.main.controller").toggle_star(pr, repo)
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
				desc = "Search repositories",
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
					statusline.notify("warn", "No PR selected")
					return
				end
				require("atlas.pulls.ui.main.controller").refresh_pr(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			callback = function()
				require("atlas.pulls.ui.main.controller").refresh_current_view()
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
				local pr, repo = selected_pr()
				if pr == nil or repo == nil then
					statusline.notify("warn", "No repository selected")
					return
				end

				local layout = require("atlas.ui.layout")
				local ui_state = require("atlas.ui.state")
				local panel = require("atlas.pulls.ui.panel")
				local panel_state = require("atlas.pulls.ui.panel.state")
				local detail_open = layout.win_id("detail") ~= nil

				if detail_open and panel_state.current_panel == "repo" then
					layout.toggle_detail()
					return
				end

				panel_state.current_panel = "repo"

				if not detail_open then
					layout.toggle_detail()
					if ui_state.on_panel_open then
						ui_state.on_panel_open()
					end
					return
				end

				panel.on_select(pr, repo)
			end,
		})
	)
	help.register("General", general, { buffer = buf })
end

return M
