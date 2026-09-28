local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local explorer_keymaps = require("atlas.pulls.pipelines.ui.explorer.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")
local logs_keymaps = require("atlas.pulls.pipelines.ui.logs.keymaps")
local help = require("atlas.ui.popups.help")

---@param pane PullsPipelinesExplorer|PullsPipelinesLogs|PullsPipelinesConfig
---@param explorer_pane PullsPipelinesExplorer
---@return PullsPipelinesSelection|nil
local function current_selection(pane, explorer_pane)
	if pane == explorer_pane then
		return explorer.current_selection(explorer_pane)
	end
	return pane.selection
end

---@param pane PullsPipelinesExplorer|PullsPipelinesLogs|PullsPipelinesConfig
---@param explorer_pane PullsPipelinesExplorer
---@param logs_pane PullsPipelinesLogs
---@param close fun()
---@param open_actions fun(selection: PullsPipelinesSelection|nil)
---@return AtlasHelpKeyItem[]
local function shared_items(pane, explorer_pane, logs_pane, close, open_actions)
	local close_keys = keymaps.resolve("ui.close") or {}
	local items = {
		{
			key = keymaps.resolve("ui.refresh_view") or {},
			desc = "Refresh build",
			callback = function()
				explorer.reload_pipeline(explorer_pane, current_selection(pane, explorer_pane))
			end,
			index = 0,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("pulls.pipelines.next_job") or {},
			desc = "Next job",
			callback = function()
				explorer.navigate_job(explorer_pane, 1, current_selection(pane, explorer_pane))
			end,
			index = 7,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("pulls.pipelines.previous_job") or {},
			desc = "Previous job",
			callback = function()
				explorer.navigate_job(explorer_pane, -1, current_selection(pane, explorer_pane))
			end,
			index = 8,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("pulls.pipelines.show_history") or {},
			desc = "Show build history",
			callback = function()
				explorer.show_history(explorer_pane)
			end,
			index = 6,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("ui.open_in_browser") or {},
			desc = "Open job or pipeline in browser",
			callback = function()
				local selection = current_selection(pane, explorer_pane)
				local url = selection
					and (selection.job and selection.job.url or selection.pipeline and selection.pipeline.url)
				if url and url ~= "" then
					vim.ui.open(url)
				end
			end,
			index = 2,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("ui.open_actions") or {},
			desc = "Open pipeline actions",
			callback = function()
				open_actions(current_selection(pane, explorer_pane))
			end,
			index = 3,
			opts = { nowait = true, silent = true },
		},
		{
			key = close_keys,
			desc = "Close pipelines",
			callback = close,
			index = 5,
			opts = { nowait = true, silent = true },
		},
		{
			key = keymaps.resolve("ui.help") or {},
			desc = "Toggle help",
			callback = function()
				help.toggle({ buffer = pane.buf })
			end,
			index = 4,
			opts = { nowait = true, silent = true },
		},
	}
	if pane == explorer_pane or pane == logs_pane then
		items[#items + 1] = {
			key = keymaps.resolve("pulls.pipelines.toggle_auto_refresh") or {},
			desc = "Toggle auto refresh",
			callback = function()
				logs.toggle_auto_refresh(logs_pane)
			end,
			index = 9,
			opts = { nowait = true, silent = true },
		}
		items[#items + 1] = {
			key = keymaps.resolve("pulls.pipelines.toggle_raw_logs") or {},
			desc = "Toggle raw logs",
			callback = function()
				logs.toggle_raw(logs_pane)
			end,
			index = 1,
			opts = { nowait = true, silent = true },
		}
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
function M.setup(session, close, open_actions)
	local explorer_items = explorer_keymaps.items(session.explorer, session.logs.win)
	local logs_items = logs_keymaps.items(session.logs)

	for _, pane in ipairs({ session.explorer, session.logs, session.config }) do
		help.register(
			"General",
			shared_items(pane, session.explorer, session.logs, close, open_actions),
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
	end
end

return M
