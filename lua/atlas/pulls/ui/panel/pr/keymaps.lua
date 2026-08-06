local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local actions = require("atlas.pulls.actions")

---@return PullsPanelTabModule|nil
local function current_tab_mod()
	local provider = require("atlas.pulls.state").provider
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
	local nav = require("atlas.pulls.ui.panel.pr.navigation")

	utils.insert_if(
		items,
		item("ui.next_item", {
			desc = "Next selectable item",
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
			desc = "Previous selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.move_cursor("up")
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open in browser",
			opts = { nowait = true, silent = true },
			callback = function()
				if M.open_current_line() then
					return
				end
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				actions.open_in_browser(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Refresh tab",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = panel_state.current_pr
				local repo = panel_state.current_repo
				if pr then
					require("atlas.pulls.ui.panel").on_select(pr, repo, { force_refresh = true })
				end
			end,
		})
	)

	local state = require("atlas.pulls.state")
	if state.provider and state.provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open PR actions",
				callback = function()
					local pr = panel_state.current_pr
					if pr == nil then
						return
					end
					actions.open_actions(pr, "panel")
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			opts = { nowait = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr == nil then
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
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				actions.checkout(pr)
			end,
		})
	)

	if state.provider and state.provider.capabilities.core and state.provider.capabilities.core.update_title then
		utils.insert_if(
			items,
			item("pulls.edit_title", {
				desc = "Edit PR title",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = panel_state.current_pr
					if pr == nil then
						return
					end
					actions.edit_title(pr, function(ok)
						if ok then
							require("atlas.pulls.ui.panel").render()
						end
					end)
				end,
			})
		)
	end

	if panel_state.current_pr and actions.is_action_available(panel_state.current_pr, "toggle_subscription") then
		utils.insert_if(
			items,
			item("ui.toggle_subscription", {
				desc = "Toggle subscription",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = panel_state.current_pr
					if pr == nil then
						return
					end
					actions.run_action(pr, "toggle_subscription", { source = "panel" }, function(_, _)
						require("atlas.pulls.ui.panel").render()
					end)
				end,
			})
		)
	end

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
	local pr = panel_state.current_pr
	if not entry or not pr then
		return false
	end

	local tab_mod = current_tab_mod()
	if tab_mod and tab_mod.on_enter then
		return tab_mod.on_enter(pr, entry) == true
	end
	return false
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, remove_item("ui.next_item"))
	utils.insert_if(general, remove_item("ui.previous_item"))
	utils.insert_if(general, remove_item("ui.refresh"))
	utils.insert_if(general, remove_item("ui.open_actions"))
	utils.insert_if(general, remove_item("ui.open_in_browser"))
	utils.insert_if(general, remove_item("pulls.open_diff"))
	utils.insert_if(general, remove_item("pulls.checkout"))
	utils.insert_if(general, remove_item("pulls.edit_title"))
	utils.insert_if(general, remove_item("ui.toggle_subscription"))
	utils.insert_if(general, remove_item("ui.next_panel_tab"))
	utils.insert_if(general, remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, remove_item("ui.help"))
	utils.insert_if(general, remove_item("ui.toggle_panel"))
	utils.insert_if(general, remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
