local M = {}

local footer = require("atlas.ui.components.footer")
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
	if type(repo) ~= "table" then
		return nil
	end

	local raw = type(repo._raw) == "table" and repo._raw or {}
	local raw_links = type(raw.links) == "table" and raw.links or {}
	local html_link = type(raw_links.html) == "table" and raw_links.html or {}
	local url = tostring(repo.html_url or raw.html_url or raw.url or html_link.href or "")
	if url ~= "" then
		return url
	end
	return nil
end

---@param buf integer
function M.register(buf)
	M.remove(buf)
	local nav = require("atlas.pulls.ui.panel.repo.navigation")
	help.register("Panel", {
		{
			key = "j",
			desc = "Next selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.move_cursor("down")
			end,
		},
		{
			key = "k",
			desc = "Previous selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.move_cursor("up")
			end,
		},
		{
			key = "gg",
			desc = "First selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.focus_first()
			end,
		},
		{
			key = "G",
			desc = "Last selectable item",
			opts = { nowait = true, silent = true },
			hidden = true,
			callback = function()
				nav.focus_last()
			end,
		},
		{
			key = "r",
			desc = "Refresh tab",
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.pulls.ui.panel").on_select(nil, nil, { force_refresh = true })
			end,
		},
		{
			key = "gx",
			desc = "Open in browser",
			opts = { nowait = true, silent = true },
			callback = function()
				M.open_current_line()
			end,
		},
		{
			key = "o",
			desc = "Close repo panel",
			opts = { nowait = true, silent = true },
			callback = function()
				local layout_mod = require("atlas.ui.layout")
				local ui_st = require("atlas.ui.state")
				layout_mod.toggle_detail()
				if ui_st.on_panel_close then
					ui_st.on_panel_close()
				end
			end,
		},
	}, { index = 211, buffer = buf })

	local general = {}

	utils.insert_if(general, item("ui.next_panel_tab", {
		desc = "Next panel tab",
		opts = { nowait = true },
		callback = function()
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_next_tab then
				ui_st.on_panel_next_tab()
			end
		end,
	}))

	utils.insert_if(general, item("ui.previous_panel_tab", {
		desc = "Previous panel tab",
		opts = { nowait = true },
		callback = function()
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_prev_tab then
				ui_st.on_panel_prev_tab()
			end
		end,
	}))

	utils.insert_if(general, item("ui.help", {
		desc = "Toggle help",
		opts = { nowait = true, silent = true },
		callback = function()
			help.toggle({ buffer = buf })
		end,
	}))

	utils.insert_if(general, item("ui.close", {
		desc = "Close panel",
		opts = { nowait = true, silent = true },
		callback = function()
			if help.is_open() then
				return
			end
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			layout_mod.toggle_detail()
			if ui_st.on_panel_close then
				ui_st.on_panel_close()
			end
		end,
	}))

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
	local repo = panel_state.current_repo_details or panel_state.current_repo

	local repo_panel = require("atlas.pulls.ui.panel.repo")
	local tab_mod = repo_panel.get_tab_module(panel_state.current_tab)
	if entry and tab_mod and type(tab_mod.on_enter) == "function" and repo then
		if tab_mod.on_enter(repo, entry) == true then
			return true
		end
	end

	local url = repo_url(repo)
	if url == nil or url == "" then
		footer.notify("warn", "No repository URL available")
		return false
	end
	vim.ui.open(url)
	footer.notify("info", "Opened repository in browser")
	return true
end

---@param buf integer
function M.remove(buf)
	local panel_items = {
		{ key = "j" },
		{ key = "k" },
		{ key = "gg" },
		{ key = "G" },
		{ key = "r" },
		{ key = "gx" },
		{ key = "o" },
	}

	local general_items = {
		remove_item("ui.next_panel_tab"),
		remove_item("ui.previous_panel_tab"),
		remove_item("ui.help"),
		remove_item("ui.close"),
	}

	help.remove("Panel", panel_items, { buffer = buf })
	help.remove("General", vim.tbl_filter(function(v)
		return v ~= nil
	end, general_items), { buffer = buf })
end

return M
