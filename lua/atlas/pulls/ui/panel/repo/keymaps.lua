local M = {}

local statusline = require("atlas.ui.statusline")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

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

---@param repo PullsRepo|nil
---@return string|nil
local function repo_url(repo)
	if repo == nil then
		return nil
	end

	local url = tostring(repo.html_url or "")
	if url ~= "" then
		return url
	end
	return nil
end

---@param buf integer
function M.register(buf)
	M.remove(buf)
	local nav = require("atlas.pulls.ui.panel.repo.navigation")
	local general = {
		{
			key = "o",
			desc = "Close repo panel",
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.ui.layout").toggle_detail()
			end,
		},
	}

	utils.insert_if(
		general,
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
		general,
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
		general,
		item("ui.first_item", {
			desc = "First selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.focus_first()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.last_item", {
			desc = "Last selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.focus_last()
			end,
		})
	)

	local refresh_item = {
		desc = "Refresh tab",
		opts = { nowait = true, silent = true },
		callback = function()
			require("atlas.pulls.ui.panel").on_select(nil, nil, { force_refresh = true })
		end,
	}
	utils.insert_if(general, item("ui.refresh", refresh_item))
	utils.insert_if(general, item("ui.refresh_view", refresh_item))

	utils.insert_if(
		general,
		item("ui.open_in_browser", {
			desc = "Open in browser",
			opts = { nowait = true, silent = true },
			callback = function()
				M.open_current_line()
			end,
		})
	)

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
	local panel_state = require("atlas.pulls.ui.panel.repo.state")
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = (panel_state.line_map or {})[lnum]
	local details = panel_state.current_repo_details
	local repo = type(details) == "table" and details or panel_state.current_repo

	local repo_panel = require("atlas.pulls.ui.panel.repo")
	local tab_mod = repo_panel.get_tab_module(panel_state.current_tab)
	if entry and tab_mod and tab_mod.on_enter and repo then
		if tab_mod.on_enter(repo, entry) == true then
			return true
		end
	end

	local url = repo_url(repo)
	if url == nil or url == "" then
		statusline.notify("warn", "No repository URL available")
		return false
	end
	vim.ui.open(url)
	statusline.notify("info", "Opened repository in browser")
	return true
end

---@param buf integer
function M.remove(buf)
	local general_items = {
		{ key = "o" },
	}

	utils.insert_if(general_items, remove_item("ui.next_item"))
	utils.insert_if(general_items, remove_item("ui.previous_item"))
	utils.insert_if(general_items, remove_item("ui.first_item"))
	utils.insert_if(general_items, remove_item("ui.last_item"))
	utils.insert_if(general_items, remove_item("ui.refresh"))
	utils.insert_if(general_items, remove_item("ui.refresh_view"))
	utils.insert_if(general_items, remove_item("ui.open_in_browser"))
	utils.insert_if(general_items, remove_item("ui.next_panel_tab"))
	utils.insert_if(general_items, remove_item("ui.previous_panel_tab"))
	utils.insert_if(general_items, remove_item("ui.help"))
	utils.insert_if(general_items, remove_item("ui.close"))

	help.remove("General", general_items, { buffer = buf })
end

return M
