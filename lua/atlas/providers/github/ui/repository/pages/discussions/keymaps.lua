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
				opts = { silent = true, nowait = true },
			})
		end
	end

	help.register("General", groups.General, { buffer = buf, index = 1 })
	help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	return groups
end

---@param state RepositoryDiscussions
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh discussions",
			callback = function()
				callbacks.refresh(state)
			end,
			index = 80,
		},
		{
			key = vim.list_extend(resolver.resolve("ui.edit_search") or {}, resolver.resolve("ui.search") or {}),
			desc = "Edit search",
			group = "Filters",
			callback = function()
				callbacks.edit_query(state)
			end,
			index = 1,
		},
		{
			key = { "t" },
			desc = "Toggle open/closed discussions",
			group = "Filters",
			callback = function()
				callbacks.toggle_state(state)
			end,
			index = 10,
		},
		{
			key = { "c" },
			desc = "Filter by category",
			group = "Filters",
			callback = function()
				callbacks.select_category(state)
			end,
			index = 11,
		},
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next discussions",
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous discussions",
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
				key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_panel") or {}),
				desc = "Open discussion",
				callback = function()
					callbacks.open_discussion(state)
				end,
				index = 1,
			},
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open discussion in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
			{
				key = resolver.resolve("ui.copy_url"),
				desc = "Copy discussion URL",
				callback = function()
					callbacks.copy_url(state)
				end,
				index = 9,
			},
		})
	)
end

return M
