local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local state = require("atlas.issues.ui.detail.state")

---@return IssuesDetailTabModule|nil
local function current_tab_mod()
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			return tab.mod
		end
	end
end

---@return boolean
local function open_current_line()
	local win = state.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = state.line_map[lnum]
	local issue = state.current_details or state.current_issue
	if not entry or not issue then
		return false
	end

	local tab = current_tab_mod()
	if tab and tab.on_enter then
		return tab.on_enter(issue, entry) == true
	end
	return false
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
	local nav = require("atlas.issues.ui.detail.navigation")
	local provider = assert(state.provider)
	local function context(issue)
		return { provider = provider, issue = issue }
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
			require("atlas.issues.ui.detail").refresh()
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
					local issue = state.current_details or state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.open(context(issue), function(result)
						if result and result.issue_key then
							if on_update then
								on_update(issue, result)
							else
								require("atlas.issues.ui.detail").select(issue, { force_refresh = true })
							end
						end
					end)
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
				if open_current_line() then
					return
				end
				local issue = state.current_details or state.current_issue
				if issue then
					actions.run("browse_issue", context(issue))
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_subscription", {
			desc = "Toggle subscription",
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = state.current_details or state.current_issue
				if issue then
					local on_update = state.on_update
					actions.run("toggle_subscription", context(issue), function(result)
						if result and result.issue_key then
							if on_update then
								on_update(issue, result)
							else
								require("atlas.issues.ui.detail").select(issue, { force_refresh = true })
							end
						end
					end)
				end
			end,
		})
	)

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		item("ui.next_panel_tab", {
			desc = "Next detail tab",
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").next_tab()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").prev_tab()
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
				require("atlas.issues.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.close", {
			desc = "Close detail panel",
			opts = { nowait = true, silent = true },
			callback = function()
				if not help.is_open() then
					require("atlas.issues.ui.detail").close()
				end
			end,
		})
	)

	help.register("General", general, { index = 300, buffer = buf })
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
