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

---@param state RepositoryReleases
---@param callbacks table<string, function>
function M.setup(state, callbacks)
	local actions = {
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh release",
			callback = function()
				callbacks.refresh(state)
			end,
			index = 80,
		},
		{
			key = resolver.resolve("ui.search"),
			desc = "Search releases",
			group = "Filters",
			callback = function()
				callbacks.search(state)
			end,
			index = 1,
		},
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next release",
			callback = function()
				callbacks.next_release(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous release",
			callback = function()
				callbacks.previous_release(state)
			end,
			index = 15,
		},
	}

	state.keymaps = register(state.sidebar_buf, actions)
	register(
		state.buf,
		vim.list_extend(actions, {
			{
				key = resolver.resolve("ui.open_in_browser"),
				desc = "Open in browser",
				callback = function()
					callbacks.open_in_browser(state)
				end,
				index = 4,
			},
			{
				key = resolver.resolve("ui.copy_id"),
				desc = "Copy release tag",
				callback = function()
					callbacks.copy_tag(state)
				end,
				index = 8,
			},
			{
				key = resolver.resolve("ui.copy_url"),
				desc = "Copy URL",
				callback = function()
					callbacks.copy_url(state)
				end,
				index = 9,
			},
		})
	)
end

return M
