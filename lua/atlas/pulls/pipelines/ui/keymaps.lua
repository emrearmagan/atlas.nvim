local M = {}

local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local explorer_keymaps = require("atlas.pulls.pipelines.ui.explorer.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")
local logs_keymaps = require("atlas.pulls.pipelines.ui.logs.keymaps")
local overview_keymaps = require("atlas.pulls.pipelines.ui.overview.keymaps")
local help = require("atlas.ui.popups.help")

---@param pane PullsPipelinesExplorer|PullsPipelinesLogs|PullsPipelinesOverview|PullsPipelinesConfig
---@param explorer_pane PullsPipelinesExplorer
---@return PullsPipelinesSelection|nil
local function current_selection(pane, explorer_pane)
	if pane == explorer_pane then
		return explorer.current_selection(explorer_pane)
	end
	return pane.selection
end

---@param pane PullsPipelinesExplorer|PullsPipelinesLogs|PullsPipelinesOverview|PullsPipelinesConfig
---@param explorer_pane PullsPipelinesExplorer
---@param logs_pane PullsPipelinesLogs
---@param close fun()
---@param open_actions fun(selection: PullsPipelinesSelection|nil)
---@param toggle_config fun(selection: PullsPipelinesSelection|nil)
---@return AtlasHelpKeyItem[]
local function shared_items(pane, explorer_pane, logs_pane, close, open_actions, toggle_config)
	local bindings = {
		{
			keymap = keymaps.resolve("ui.refresh_view"),
			callback = function()
				explorer.reload_pipeline(explorer_pane, current_selection(pane, explorer_pane))
			end,
			index = 50,
		},
		{
			keymap = keymaps.resolve("pulls.pipelines.next_job"),
			callback = function()
				explorer.navigate_job(explorer_pane, 1, current_selection(pane, explorer_pane))
			end,
			index = 11,
		},
		{
			keymap = keymaps.resolve("pulls.pipelines.previous_job"),
			callback = function()
				explorer.navigate_job(explorer_pane, -1, current_selection(pane, explorer_pane))
			end,
			index = 10,
		},
		{
			keymap = keymaps.resolve("pulls.pipelines.show_history"),
			callback = function()
				explorer.show_history(explorer_pane)
			end,
			index = 20,
		},
		{
			keymap = keymaps.resolve("ui.open_in_browser"),
			callback = function()
				local selection = current_selection(pane, explorer_pane)
				local url = selection
					and (selection.job and selection.job.url or selection.pipeline and selection.pipeline.url)
				if url and url ~= "" then
					vim.ui.open(url)
				end
			end,
			index = 21,
		},
		{
			keymap = keymaps.resolve("ui.copy_url"),
			callback = function()
				local selection = current_selection(pane, explorer_pane)
				local url = selection
					and (selection.job and selection.job.url or selection.pipeline and selection.pipeline.url)
				if url and url ~= "" then
					vim.fn.setreg("+", url)
					notify.success("Copied URL")
				end
			end,
			index = 23,
		},
		{
			keymap = keymaps.resolve("pulls.pipelines.toggle_config"),
			callback = function()
				toggle_config(current_selection(pane, explorer_pane))
			end,
			index = 22,
		},
		{
			keymap = keymaps.resolve("ui.open_actions"),
			callback = function()
				open_actions(current_selection(pane, explorer_pane))
			end,
			index = 30,
		},
		{
			keymap = keymaps.resolve("ui.close"),
			callback = close,
			index = 101,
		},
		{
			keymap = keymaps.resolve("ui.help"),
			callback = function()
				help.toggle({ buffer = pane.buf })
			end,
			index = 100,
		},
	}
	if pane == explorer_pane or pane == logs_pane then
		bindings[#bindings + 1] = {
			keymap = keymaps.resolve("pulls.pipelines.toggle_auto_refresh"),
			callback = function()
				logs.toggle_auto_refresh(logs_pane)
			end,
			index = 51,
		}
		bindings[#bindings + 1] = {
			keymap = keymaps.resolve("pulls.pipelines.toggle_raw_logs"),
			callback = function()
				logs.toggle_raw(logs_pane)
			end,
			index = 52,
		}
	end

	local items = {}
	for _, binding in ipairs(bindings) do
		if binding.keymap then
			items[#items + 1] = {
				key = binding.keymap.key,
				desc = binding.keymap.desc,
				callback = binding.callback,
				index = binding.index,
				opts = { nowait = true, silent = true },
			}
		end
	end
	return items
end

---@param items AtlasHelpKeyItem[]
---@return AtlasHelpKeyItem[]
local function references(items)
	local result = {}
	for _, item in ipairs(items) do
		result[#result + 1] = { key = item.key, desc = item.desc, index = item.index }
	end
	return result
end

---@param session PullsPipelinesSession
---@param close fun()
---@param open_actions fun(selection: PullsPipelinesSelection|nil)
---@param toggle_config fun(selection: PullsPipelinesSelection|nil)
function M.setup(session, close, open_actions, toggle_config)
	local explorer_items = explorer_keymaps.items(session.explorer, session.logs.win)
	local logs_items = logs_keymaps.items(session.logs)
	local overview_items = overview_keymaps.items(session.overview, session.explorer)

	for _, pane in ipairs({ session.explorer, session.logs, session.overview, session.config }) do
		help.register(
			"General",
			shared_items(pane, session.explorer, session.logs, close, open_actions, toggle_config),
			{ buffer = pane.buf, index = 0 }
		)
		help.register(
			"Explorer",
			pane == session.explorer and explorer_items or references(explorer_items),
			{ buffer = pane.buf, index = 100 }
		)
		help.register(
			"Logs",
			pane == session.logs and logs_items or references(logs_items),
			{ buffer = pane.buf, index = 200 }
		)
		help.register(
			"Overview",
			pane == session.overview and overview_items or references(overview_items),
			{ buffer = pane.buf, index = 300 }
		)
	end
end

---@param session PullsPipelinesSession
---@param buf integer
---@return AtlasKeymapActionId[]
function M.hints(session, buf)
	if buf == session.logs.buf then
		return {
			"ui.toggle_fold",
			"pulls.pipelines.toggle_raw_logs",
			"pulls.pipelines.toggle_auto_refresh",
		}
	end

	return {
		"ui.select",
		"ui.open_actions",
		"pulls.pipelines.toggle_config",
	}
end

return M
