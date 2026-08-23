local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")

---@param items table[]
---@param action_id string
---@param callback fun()
---@param desc string
---@param index integer
local function add_help_action(items, action_id, callback, desc, index)
	local keys = keymaps.resolve(action_id)
	if not keys or #keys == 0 then
		return
	end
	table.insert(items, {
		key = #keys == 1 and keys[1] or keys,
		desc = desc,
		index = index,
		callback = callback,
		opts = { silent = true, nowait = true },
	})
end

---@param buf integer
---@param title string
---@param actions { close: fun(), show_logs: fun(), refresh: fun(), open_url: fun(), open_actions: fun() }
function M.setup_pipelines(buf, title, actions)
	local items = {}
	local log_keys = keymaps.resolve("ui.show_details") or {}
	vim.list_extend(log_keys, keymaps.resolve("ui.select") or {})
	if #log_keys > 0 then
		table.insert(items, {
			key = log_keys,
			desc = "Show job logs",
			index = 1,
			callback = actions.show_logs,
			opts = { silent = true, nowait = true },
		})
	end
	add_help_action(items, "ui.refresh", actions.refresh, "Refresh pipelines", 2)
	add_help_action(items, "ui.open_in_browser", actions.open_url, "Open pipeline in browser", 3)
	add_help_action(items, "ui.open_actions", actions.open_actions, "Open pipeline actions", 4)
	add_help_action(items, "ui.help", function()
		help.toggle({ buffer = buf })
	end, "Toggle help", 5)
	local close_keys = keymaps.resolve("ui.close") or {}
	vim.list_extend(close_keys, keymaps.resolve("ui.toggle_panel") or {})
	if #close_keys > 0 then
		table.insert(items, {
			key = close_keys,
			desc = "Close pipelines",
			index = 6,
			callback = actions.close,
			opts = { silent = true, nowait = true },
		})
	end
	help.register(title, items, { buffer = buf, index = 100 })
end

---@param buf integer
---@param actions { close: fun(), refresh: fun(), open_url: fun() }
function M.setup_job_log(buf, actions)
	local items = {}
	add_help_action(items, "ui.refresh", actions.refresh, "Refresh job log", 1)
	add_help_action(items, "ui.open_in_browser", actions.open_url, "Open job in browser", 2)
	add_help_action(items, "ui.help", function()
		help.toggle({ buffer = buf })
	end, "Toggle help", 3)
	add_help_action(items, "ui.close", actions.close, "Close job log", 4)
	help.register("Job Log", items, { buffer = buf, index = 100 })
end

return M
