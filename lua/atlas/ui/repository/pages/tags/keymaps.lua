local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param buf integer
---@param actions table[]
---@return table<string, AtlasHelpKeyItem[]>
local function register(buf, actions)
	local groups = { General = {}, Filters = {} }
	for _, action in ipairs(actions) do
		if action.key and #action.key > 0 then
			table.insert(groups[action.group or "General"], {
				key = action.key,
				desc = action.desc,
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
		key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
		desc = "Refresh tags",
		callback = function()
			callbacks.load(state)
		end,
		index = 80,
	}

	state.keymaps = register(state.sidebar_buf, { refresh })
	register(state.buf, {
		refresh,
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next page",
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous page",
			callback = function()
				callbacks.previous_page(state)
			end,
			index = 15,
		},
		{
			key = resolver.resolve("ui.search"),
			desc = "Search tags",
			group = "Filters",
			callback = function()
				callbacks.search(state)
			end,
			index = 1,
		},
		{
			key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_fold") or {}),
			desc = "Toggle tag details",
			callback = function()
				callbacks.toggle_details(state)
			end,
			index = 1,
		},
		{
			key = resolver.resolve("pulls.open_diff"),
			desc = "Open diff",
			callback = function()
				callbacks.open_diff(state)
			end,
			index = 2,
		},
		{
			key = resolver.resolve("ui.show_details"),
			desc = "Show tag details",
			callback = function()
				callbacks.show_details(state)
			end,
			index = 3,
		},
		{
			key = resolver.resolve("ui.open_in_browser"),
			desc = "Open tag in browser",
			callback = function()
				callbacks.open_in_browser(state)
			end,
			index = 4,
		},
		{
			key = resolver.resolve("ui.copy_id"),
			desc = "Copy commit SHA",
			callback = function()
				callbacks.copy_sha(state)
			end,
			index = 8,
		},
		{
			key = resolver.resolve("ui.copy_url"),
			desc = "Copy tag URL",
			callback = function()
				callbacks.copy_url(state)
			end,
			index = 9,
		},
	})
end

return M
