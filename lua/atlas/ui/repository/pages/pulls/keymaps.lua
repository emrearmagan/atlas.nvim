local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param buf integer
---@param actions table[]
---@return table<string, AtlasHelpKeyItem[]>
local function register(buf, actions)
	local groups = { General = {}, Filters = {} }
	for _, action in ipairs(actions) do
		if action.keymap then
			table.insert(groups[action.group or "General"], {
				key = action.keymap.key,
				desc = action.keymap.desc,
				index = action.index,
				callback = action.callback,
				opts = { silent = true, nowait = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	return groups
end

---@param state RepositoryPulls
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			keymap = resolver.resolve({ "ui.refresh", "ui.refresh_view" }),
			callback = function()
				callbacks.refresh(state)
			end,
			index = 80,
		},
		{
			keymap = resolver.resolve({ "ui.edit_search", "ui.search" }),
			group = "Filters",
			callback = function()
				callbacks.edit_query(state)
			end,
			index = 1,
		},
		{
			keymap = resolver.resolve("ui.next_page"),
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			keymap = resolver.resolve("ui.previous_page"),
			callback = function()
				callbacks.previous_page(state)
			end,
			index = 15,
		},
	}

	for index, filter in ipairs({ "open", "merged", "declined" }) do
		table.insert(actions, {
			keymap = resolver.resolve("pulls.filters." .. filter --[[@as AtlasKeymapActionId]]),
			group = "Filters",
			callback = function()
				callbacks.toggle_filter(state, filter)
			end,
			index = 10 + index,
		})
	end

	state.keymaps = register(state.sidebar_buf, actions)
	register(
		state.buf,
		vim.list_extend(actions, {
			{
				keymap = resolver.resolve("pulls.open_diff"),
				callback = function()
					callbacks.open_diff(state)
				end,
				index = 2,
			},
			{
				keymap = resolver.resolve({ "ui.select", "ui.toggle_panel" }),
				callback = function()
					callbacks.open_panel(state)
				end,
				index = 1,
			},
			{
				keymap = resolver.resolve("ui.open_in_browser"),
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
		})
	)
end

return M
