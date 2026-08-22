local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local actions = require("atlas.issues.actions")

---@return IssuesPanelTabModule|nil
local function current_tab_mod()
	local provider = require("atlas.issues.state").provider
	local panel = provider and provider.capabilities.ui and provider.capabilities.ui.panel
	if panel and panel.tabs then
		for _, tab in ipairs(panel.tabs() or {}) do
			if tab.key == panel_state.current_tab then
				return tab.mod
			end
		end
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

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@param buf integer
function M.register(buf)
	local items = {}
	local nav = require("atlas.issues.ui.panel.issue.navigation")
	local controller = require("atlas.issues.ui.main.controller")
	local state = require("atlas.issues.state")
	local provider = assert(state.provider)
	local function context(issue)
		return { provider = provider, issue = issue, current_user = state.current_user }
	end

	utils.insert_if(
		items,
		item("ui.next_item", {
			desc = "Next item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.move_cursor("down")
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.previous_item", {
			desc = "Previous item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.move_cursor("up")
			end,
		})
	)
	local refresh_item = {
		desc = "Refresh issue",
		opts = { nowait = true, silent = true },
		callback = function()
			controller.refresh_issue(panel_state.current_issue)
		end,
	}
	utils.insert_if(items, item("ui.refresh", refresh_item))
	utils.insert_if(items, item("ui.refresh_view", refresh_item))

	if provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open issue actions",
				callback = function()
					local issue = panel_state.current_details or panel_state.current_issue
					if issue == nil then
						return
					end
					actions.open(context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open issue in browser",
			opts = { nowait = true },
			callback = function()
				if M.open_current_line() then
					return
				end
				local issue = panel_state.current_details or panel_state.current_issue
				if issue == nil then
					return
				end
				actions.run("browse_issue", context(issue))
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_subscription", {
			desc = "Toggle subscription",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = panel_state.current_details or panel_state.current_issue
				if issue == nil then
					return
				end
				actions.run("toggle_subscription", context(issue), controller.apply_action_result)
			end,
		})
	)

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		item("ui.next_panel_tab", {
			desc = "Next panel tab",
			opts = { nowait = true },
			callback = function()
				local layout_mod = require("atlas.ui.layout")
				local ui_st = require("atlas.ui.state")
				if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_next_tab then
					ui_st.on_panel_next_tab()
				end
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.previous_panel_tab", {
			desc = "Previous panel tab",
			opts = { nowait = true },
			callback = function()
				local layout_mod = require("atlas.ui.layout")
				local ui_st = require("atlas.ui.state")
				if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_prev_tab then
					ui_st.on_panel_prev_tab()
				end
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.help", {
			desc = "Toggle help",
			opts = { nowait = true, silent = true },
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			callback = function()
				local layout_mod = require("atlas.ui.layout")
				local ui_st = require("atlas.ui.state")
				local was_open = layout_mod.win_id("detail") ~= nil
				layout_mod.toggle_detail()
				if not was_open then
					if ui_st.on_panel_open then
						ui_st.on_panel_open()
					end
				end
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.close", {
			desc = "Close panel",
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				require("atlas.ui.layout").toggle_detail()
			end,
		})
	)

	help.register("General", general, { index = 300, buffer = buf })
end

---@return boolean
function M.open_current_line()
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = (panel_state.line_map or {})[lnum]
	local issue = panel_state.current_details or panel_state.current_issue
	if not entry or not issue then
		return false
	end

	local tab_mod = current_tab_mod()
	if tab_mod and tab_mod.on_enter then
		return tab_mod.on_enter(issue, entry) == true
	end
	return false
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, remove_item("ui.next_item"))
	utils.insert_if(general, remove_item("ui.previous_item"))
	utils.insert_if(general, remove_item("ui.refresh"))
	utils.insert_if(general, remove_item("ui.refresh_view"))
	utils.insert_if(general, remove_item("ui.open_actions"))
	utils.insert_if(general, remove_item("ui.open_in_browser"))
	utils.insert_if(general, remove_item("ui.toggle_subscription"))
	utils.insert_if(general, remove_item("ui.next_panel_tab"))
	utils.insert_if(general, remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, remove_item("ui.help"))
	utils.insert_if(general, remove_item("ui.toggle_panel"))
	utils.insert_if(general, remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
