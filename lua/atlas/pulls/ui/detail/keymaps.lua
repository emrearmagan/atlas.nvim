local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local actions = require("atlas.pulls.actions")
local notify = require("atlas.core.notify")

---@param pr PullRequest
---@param buf integer|nil
---@return AtlasPullActionContext|nil
local function action_context(pr, buf)
	local provider = state.provider
	if not provider then
		return nil
	end
	return {
		provider = provider,
		pr = pr,
		buf = buf,
		notify = function(level, message, duration)
			notify.show(level, message, { timeout = duration })
		end,
	}
end

---@param pr PullRequest
---@param on_update (fun(pr: PullRequest, result: PullsActionResult|nil))|nil
---@param result PullsActionResult|nil
local function complete_action(pr, on_update, result)
	if not result or not result.changed_pr then
		return
	end
	if on_update then
		on_update(pr, result)
	else
		require("atlas.pulls.ui.detail").select(pr, { force_refresh = true })
	end
end

---@return PullsDetailTabModule|nil
local function current_tab_mod()
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			return tab.mod
		end
	end
end

---@param action_id string
---@return boolean
local function supports_action(action_id)
	local capability = state.provider and state.provider.capabilities.actions
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == action_id then
			return true
		end
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

---@return boolean
local function open_current_line()
	local win = state.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = (state.line_map or {})[lnum]
	local pr = state.current_details or state.current_pr
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
function M.register(buf)
	local items = {}
	local nav = require("atlas.pulls.ui.detail.navigation")

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
				if open_current_line() then
					return
				end
				local pr = state.current_details or state.current_pr
				if pr == nil then
					return
				end
				local context = action_context(pr, buf)
				if context then
					actions.run("open_in_browser", context)
				end
			end,
		})
	)

	local refresh_item = {
		desc = "Refresh tab",
		opts = { nowait = true, silent = true },
		callback = function()
			require("atlas.pulls.ui.detail").refresh()
		end,
	}
	utils.insert_if(items, item("ui.refresh", refresh_item))
	utils.insert_if(items, item("ui.refresh_view", refresh_item))

	if state.provider and state.provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open PR actions",
				callback = function()
					local pr = state.current_details or state.current_pr
					if pr == nil then
						return
					end
					local context = action_context(pr, buf)
					if context then
						local on_update = state.on_update
						actions.open(context, function(result)
							complete_action(pr, on_update, result)
						end)
					end
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
				local pr = state.current_details or state.current_pr
				if pr == nil then
					return
				end
				local context = action_context(pr, buf)
				if context then
					actions.run("open_diff", context)
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.checkout", {
			desc = "Checkout PR branch",
			opts = { nowait = true },
			callback = function()
				local pr = state.current_details or state.current_pr
				if pr == nil then
					return
				end
				local context = action_context(pr, buf)
				if context then
					actions.run("checkout", context)
				end
			end,
		})
	)

	if supports_action("edit_title") then
		utils.insert_if(
			items,
			item("pulls.edit_title", {
				desc = "Edit PR title",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_details or state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("edit_title", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	if supports_action("edit_description") then
		utils.insert_if(
			items,
			item("pulls.edit_description", {
				desc = "Edit PR description",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_details or state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("edit_description", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	if supports_action("toggle_subscription") then
		utils.insert_if(
			items,
			item("ui.toggle_subscription", {
				desc = "Toggle subscription",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_details or state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("toggle_subscription", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		item("ui.next_panel_tab", {
			desc = "Next detail tab",
			opts = { nowait = true },
			callback = function()
				if require("atlas.pulls.ui.detail").is_open() then
					require("atlas.pulls.ui.detail").next_tab()
				end
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			opts = { nowait = true },
			callback = function()
				if require("atlas.pulls.ui.detail").is_open() then
					require("atlas.pulls.ui.detail").prev_tab()
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
				require("atlas.pulls.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.close", {
			desc = "Close detail panel",
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				require("atlas.pulls.ui.detail").close()
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
	utils.insert_if(general, remove_item("pulls.open_diff"))
	utils.insert_if(general, remove_item("pulls.checkout"))
	utils.insert_if(general, remove_item("pulls.edit_title"))
	utils.insert_if(general, remove_item("pulls.edit_description"))
	utils.insert_if(general, remove_item("ui.toggle_subscription"))
	utils.insert_if(general, remove_item("ui.next_panel_tab"))
	utils.insert_if(general, remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, remove_item("ui.help"))
	utils.insert_if(general, remove_item("ui.toggle_panel"))
	utils.insert_if(general, remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
