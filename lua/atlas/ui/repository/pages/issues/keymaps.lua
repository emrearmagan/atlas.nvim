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

---@param state RepositoryIssues
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh issues",
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
			desc = "Toggle open/closed issues",
			group = "Filters",
			callback = function()
				callbacks.toggle_state(state)
			end,
			index = 10,
		},
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next issues",
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous issues",
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
				desc = "Open issue panel",
				callback = function()
					callbacks.open_panel(state)
				end,
				index = 1,
			},
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open issue in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
		})
	)
end

return M
