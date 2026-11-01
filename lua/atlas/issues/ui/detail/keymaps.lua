local M = {}

local help = require("atlas.ui.popups.help")
local detail_window = require("atlas.issues.ui.detail.window")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local state = require("atlas.issues.ui.detail.state")
local links = require("atlas.ui.links")
local detail = require("atlas.issues.ui.detail")
local registrations = {}

local function open_links()
	local issue, provider = state.current_issue, state.provider
	if issue == nil or provider == nil then
		return
	end
	local loaded = state.links
	if loaded and (loaded.loading or loaded.error) then
		loaded = nil
	end
	links.select(provider, issue, "issue", loaded and loaded.items, detail.way_back())
end

---@param lnum integer
---@return boolean
local function is_selectable(lnum)
	local entry = state.line_map[lnum]
	if entry == nil then
		return false
	end

	local tab_mod = state.tab_module(state.current_tab)
	if tab_mod and tab_mod.is_selectable_line then
		return tab_mod.is_selectable_line(lnum, entry)
	end

	return true
end

---@return boolean
local function open_current_line()
	local win = state.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = state.line_map[lnum]
	local issue = state.current_issue
	if not entry or not issue then
		return false
	end

	local tab = state.tab_module(state.current_tab)
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
	map_item.key = #keys == 1 and keys[1] or keys
	return map_item
end

---@param buf integer
function M.register(buf)
	M.remove(buf)
	local items = {}
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
				detail_window.move_cursor("down", is_selectable)
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
				detail_window.move_cursor("up", is_selectable)
			end,
		})
	)
	local refresh_keys = resolver.resolve("ui.refresh") or {}
	vim.list_extend(refresh_keys, resolver.resolve("ui.refresh_view") or {})
	if #refresh_keys > 0 then
		table.insert(items, {
			key = refresh_keys,
			desc = "Refresh issue",
			index = 80,
			opts = { nowait = true, silent = true },
			callback = function()
				detail.refresh()
			end,
		})
	end

	if actions.find("edit_issue", context(state.current_issue)) then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
				desc = "Edit issue",
				index = 5,
				opts = { nowait = true, silent = true },
				callback = function()
					local issue = state.current_issue
					if issue then
						local on_update = state.on_update
						actions.run("edit_issue", context(issue), function(result)
							detail.apply_action_result(issue, on_update, result)
						end)
					end
				end,
			})
		)
	end

	if provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open issue actions",
				index = 1,
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.open(context(issue), function(result)
						detail.apply_action_result(issue, on_update, result)
					end, {
						{
							label = "Open related items",
							icon = require("atlas.ui.shared.icons").get("link"),
							callback = open_links,
						},
					})
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open issue in browser",
			index = 4,
			opts = { nowait = true },
			callback = function()
				if open_current_line() then
					return
				end
				local issue = state.current_issue
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
			index = 30,
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = state.current_issue
				if issue then
					local on_update = state.on_update
					actions.run("toggle_subscription", context(issue), function(result)
						detail.apply_action_result(issue, on_update, result)
					end)
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.open_references", {
			desc = "Open references",
			index = 3,
			opts = { nowait = true, silent = true },
			callback = open_links,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_panel_tab", {
			desc = "Next detail tab",
			index = 11,
			opts = { nowait = true },
			callback = function()
				detail.next_tab()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			index = 10,
			opts = { nowait = true },
			callback = function()
				detail.prev_tab()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.help", {
			desc = "Toggle help",
			index = 100,
			opts = { nowait = true, silent = true },
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			index = 12,
			callback = function()
				detail.close()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.close", {
			desc = "Close detail panel",
			index = 101,
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				if state.back then
					state.back()
				else
					detail.close()
				end
			end,
		})
	)

	local custom_items = resolver.custom_items("issues", function(callback)
		local issue = state.current_issue
		if issue == nil then
			return
		end
		local on_update = state.on_update
		return callback(context(issue), function(result)
			detail.apply_action_result(issue, on_update, result)
		end)
	end)
	registrations[buf] = {
		{ group = "General", items = items, index = 1 },
		{ group = "Custom", items = custom_items, index = 3 },
	}
	for _, registration in ipairs(registrations[buf]) do
		help.register(registration.group, registration.items, { index = registration.index, buffer = buf })
	end
end

---@param buf integer
function M.remove(buf)
	local registered = registrations[buf]
	if registered then
		for _, registration in ipairs(registered) do
			help.remove(registration.group, registration.items, { buffer = buf })
		end
		registrations[buf] = nil
	end
end

return M
