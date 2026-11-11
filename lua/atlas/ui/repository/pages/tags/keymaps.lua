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
				opts = { nowait = true, silent = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	return groups
end

---@param state RepositoryTags
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local refresh = {
		keymap = resolver.resolve({ "ui.refresh", "ui.refresh_view" }),
		callback = function()
			callbacks.load(state)
		end,
		index = 80,
	}

	state.keymaps = register(state.sidebar_buf, { refresh })
	register(state.buf, {
		refresh,
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
		{
			keymap = resolver.resolve("ui.search"),
			group = "Filters",
			callback = function()
				callbacks.search(state)
			end,
			index = 1,
		},
		{
			keymap = resolver.resolve({ "ui.toggle_fold", "ui.select" }),
			callback = function()
				callbacks.toggle_details(state)
			end,
			index = 1,
		},
		{
			keymap = resolver.resolve("pulls.open_diff"),
			callback = function()
				callbacks.open_diff(state)
			end,
			index = 2,
		},
		{
			keymap = resolver.resolve("ui.show_details"),
			callback = function()
				callbacks.show_details(state)
			end,
			index = 3,
		},
		{
			keymap = resolver.resolve("ui.open_in_browser"),
			callback = function()
				callbacks.open_in_browser(state)
			end,
			index = 4,
		},
		{
			keymap = resolver.resolve("ui.copy_id"),
			callback = function()
				callbacks.copy_sha(state)
			end,
			index = 8,
		},
		{
			keymap = resolver.resolve("ui.copy_url"),
			callback = function()
				callbacks.copy_url(state)
			end,
			index = 9,
		},
	})
end

return M
