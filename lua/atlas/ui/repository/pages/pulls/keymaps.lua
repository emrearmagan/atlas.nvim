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

---@param state RepositoryPulls
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh pull requests",
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
			key = resolver.resolve("ui.next_page"),
			desc = "Next pull requests",
			callback = function()
				callbacks.next_page(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous pull requests",
			callback = function()
				callbacks.previous_page(state)
			end,
			index = 15,
		},
	}

	for index, filter in ipairs({ "open", "merged", "declined" }) do
		table.insert(actions, {
			key = resolver.resolve("pulls.filters." .. filter),
			desc = "Toggle " .. filter .. " filter",
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
				key = resolver.resolve("pulls.open_diff"),
				desc = "Open pull request diff",
				callback = function()
					callbacks.open_diff(state)
				end,
				index = 2,
			},
			{
				key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_panel") or {}),
				desc = "Open pull request panel",
				callback = function()
					callbacks.open_panel(state)
				end,
				index = 1,
			},
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open pull request in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
		})
	)
end

return M
