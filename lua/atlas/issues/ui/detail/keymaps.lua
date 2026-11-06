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

---@param action_id AtlasKeymapActionId|AtlasKeymapActionId[]
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keymap = resolver.resolve(action_id)
	if keymap == nil then
		return nil
	end
	map_item.key = keymap.key
	map_item.desc = keymap.desc
	return map_item
end

---@param buf integer
function M.register(buf)
	M.remove(buf)
	local items = {}
	local provider = assert(state.provider)
	local function context(issue)
		return { provider = provider, issue = issue, details = state.current_details }
	end

	utils.insert_if(
		items,
		item("ui.next_item", {
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
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				detail_window.move_cursor("up", is_selectable)
			end,
		})
	)
	utils.insert_if(
		items,
		item({ "ui.refresh", "ui.refresh_view" }, {
			index = 80,
			opts = { nowait = true, silent = true },
			callback = function()
				detail.refresh()
			end,
		})
	)

	if actions.find("edit_issue", context(state.current_issue)) then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
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
		item("ui.copy_url", {
			index = 9,
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = state.current_issue
				if issue then
					actions.run("copy_issue_url", context(issue))
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_subscription", {
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
			index = 3,
			opts = { nowait = true, silent = true },
			callback = open_links,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_panel_tab", {
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
			index = 12,
			callback = function()
				detail.close()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.close", {
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

---@return AtlasKeymapActionId[]
function M.hints()
	return {
		"ui.comments.add",
		"ui.comments.reply",
		"issues.edit_issue",
		"ui.open_actions",
		"ui.next_panel_tab",
	}
end

return M
