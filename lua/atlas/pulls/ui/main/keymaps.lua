local M = {}

local footer = require("atlas.ui.components.footer")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")

---@return PullRequest|nil
local function selected_pr()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil
	end
	if node.kind == "pr" and type(node.pr) == "table" then
		return node.pr
	end
	if node.kind == "pr_meta" and type(node.pr) == "table" then
		return node.pr
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
---@param views AtlasPullsViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local state = require("atlas.pulls.state")
	local provider_name = state.provider and state.provider.name or "Pulls"

	local items = {}

	for _, view in ipairs(views or {}) do
		if view.key ~= nil and view.key ~= "" then
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

	local STATUS_TOGGLES = {
		{ status = "OPEN", action_id = "pulls.filter_status_open" },
		{ status = "MERGED", action_id = "pulls.filter_status_merged" },
		{ status = "DECLINED", action_id = "pulls.filter_status_declined" },
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

	if state.provider and state.provider.open_actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open PR actions",
				index = 1,
				callback = function()
					local pr = selected_pr()
					if pr == nil then
						footer.notify("warn", "No PR selected")
						return
					end
					actions.open_actions(pr, "main")
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
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.open_in_browser(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.copy_url", {
			desc = "Copy PR URL",
			opts = { nowait = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.copy_url(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.copy_id", {
			desc = "Copy PR ID",
			opts = { nowait = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.copy_id(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show PR details",
			opts = { nowait = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.show_details(pr, buf)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			opts = { nowait = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.open_diff(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.checkout", {
			desc = "Checkout PR branch",
			opts = { nowait = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end
				actions.checkout(pr)
			end,
		})
	)

	if state.provider and state.provider.search then
		utils.insert_if(
			items,
			item("ui.search", {
				desc = "Search repositories",
				callback = function()
					actions.search()
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
					footer.notify("warn", "No PR selected")
					return
				end
				actions.refresh(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			callback = function()
				actions.refresh_view()
			end,
		})
	)

	help.register(provider_name, items, { index = 220, buffer = buf })

	help.register("General", {
		{
			key = "o",
			desc = "Open repo panel",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					footer.notify("warn", "No PR selected")
					return
				end

				local layout = require("atlas.ui.layout")
				local ui_state = require("atlas.ui.state")
				local panel = require("atlas.pulls.ui.panel")
				local panel_state = require("atlas.pulls.ui.panel.state")
				local detail_open = layout.win_id("detail") ~= nil

				if detail_open and panel_state.current_panel == "repo" then
					layout.toggle_detail()
					if ui_state.on_panel_close then
						ui_state.on_panel_close()
					end
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

				panel.on_select(pr, nil)
			end,
		},
	}, { buffer = buf })
end

return M
