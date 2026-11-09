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

---@param state RepositoryIssues
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
			-- TODO: add to config
			keymap = { key = { "t" }, desc = "Toggle open/closed issues", label = "state" },
			group = "Filters",
			callback = function()
				callbacks.toggle_state(state)
			end,
			index = 10,
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

	state.keymaps = register(state.sidebar_buf, actions)
	register(
		state.buf,
		vim.list_extend(actions, {
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
			{
				keymap = resolver.resolve("ui.copy_url"),
				callback = function()
					callbacks.copy_url(state)
				end,
				index = 9,
			},
		})
	)
end

return M
