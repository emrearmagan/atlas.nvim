local M = {}

local help = require("atlas.ui.popups.help")
local detail_window = require("atlas.pulls.ui.detail.window")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local actions = require("atlas.pulls.actions")
local action_runner = require("atlas.core.actions")
local links = require("atlas.ui.links")

local registrations = {}

local function open_links()
	local pr, provider = state.current_pr, state.provider
	if pr == nil or provider == nil then
		return
	end
	local loaded = state.links
	if loaded and (loaded.loading or loaded.error) then
		loaded = nil
	end
	links.select(provider, pr, "pr", loaded and loaded.items, require("atlas.pulls.ui.detail").way_back())
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
		details = state.current_details,
		buf = buf,
	}
end

---@param action_id string
---@return boolean
local function supports_action(action_id)
	return state.provider ~= nil and action_runner.find(state.provider.capabilities.actions, action_id) ~= nil
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

---@return boolean
local function open_current_line()
	local win = state.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = state.line_map[lnum]
	local pr = state.current_pr
	if not entry or not pr then
		return false
	end

	local tab_mod = state.tab_module(state.current_tab)
	if tab_mod and tab_mod.on_enter then
		return tab_mod.on_enter(pr, entry) == true
	end
	return false
end

---@param buf integer
function M.register(buf)
	local items = {}
	local function run_pr_action(action_id)
		return function()
			local pr = state.current_pr
			if pr == nil then
				return
			end
			local current = action_context(pr)
			if current then
				local on_update = state.on_update
				actions.run(action_id, current, function(result)
					require("atlas.pulls.ui.detail").apply_action_result(pr, on_update, result)
				end)
			end
		end
	end

	utils.insert_if(
		items,
		item("ui.next_item", {
			desc = "Next selectable item",
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
			desc = "Previous selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				detail_window.move_cursor("up", is_selectable)
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.open_in_browser", {
			desc = "Open in browser",
			index = 4,
			opts = { nowait = true, silent = true },
			callback = function()
				if open_current_line() then
					return
				end
				local pr = state.current_pr
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

	local refresh_keys = resolver.resolve("ui.refresh") or {}
	vim.list_extend(refresh_keys, resolver.resolve("ui.refresh_view") or {})
	if #refresh_keys > 0 then
		table.insert(items, {
			key = refresh_keys,
			desc = "Refresh tab",
			index = 80,
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.pulls.ui.detail").refresh()
			end,
		})
	end

	if state.provider and state.provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open PR actions",
				index = 1,
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local context = action_context(pr, buf)
					if context then
						local on_update = state.on_update
						actions.open(context, function(result)
							require("atlas.pulls.ui.detail").apply_action_result(pr, on_update, result)
						end, {
							{
								label = "Open related items",
								icon = require("atlas.ui.shared.icons").get("link"),
								callback = open_links,
							},
						})
					end
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			index = 2,
			opts = { nowait = true },
			callback = function()
				local pr = state.current_pr
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
			index = 6,
			opts = { nowait = true },
			callback = function()
				local pr = state.current_pr
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

	local provider_detail = state.provider and state.provider.capabilities.ui and state.provider.capabilities.ui.detail
	if provider_detail and provider_detail.keymaps then
		for _, keymap in ipairs(provider_detail.keymaps()) do
			table.insert(items, {
				key = keymap.key,
				desc = keymap.desc,
				index = 7,
				opts = { nowait = true, silent = true },
				callback = keymap.callback,
			})
		end
	end

	if supports_action("edit_pr") then
		utils.insert_if(
			items,
			item("pulls.edit_pr", {
				desc = "Edit PR",
				index = 5,
				opts = { nowait = true, silent = true },
				callback = run_pr_action("edit_pr"),
			})
		)
	end

	if supports_action("toggle_subscription") then
		utils.insert_if(
			items,
			item("ui.toggle_subscription", {
				desc = "Toggle subscription",
				index = 30,
				opts = { nowait = true, silent = true },
				callback = run_pr_action("toggle_subscription"),
			})
		)
	end

	M.remove(buf)
	local general = items
	utils.insert_if(
		general,
		item("ui.open_references", {
			desc = "Open references",
			index = 3,
			opts = { nowait = true, silent = true },
			callback = open_links,
		})
	)

	utils.insert_if(
		general,
		item("ui.next_panel_tab", {
			desc = "Next detail tab",
			index = 11,
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
			index = 10,
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
			index = 100,
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
			index = 12,
			callback = function()
				require("atlas.pulls.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
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
					require("atlas.pulls.ui.detail").close()
				end
			end,
		})
	)

	local custom_items = resolver.custom_items("pulls", function(callback)
		local pr = state.current_pr
		if not pr then
			return
		end
		local context = action_context(pr, buf)
		local on_update = state.on_update
		if context then
			return callback(context, function(result)
				require("atlas.pulls.ui.detail").apply_action_result(pr, on_update, result)
			end)
		end
	end)
	registrations[buf] = {
		{ group = "General", items = general, index = 1 },
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
