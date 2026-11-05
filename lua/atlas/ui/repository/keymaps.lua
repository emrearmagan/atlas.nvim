local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param session RepositoryBrowser
---@param close fun()
---@param select_page fun(index: integer)
function M.setup(session, close, select_page)
	for _, pane in ipairs({ session.sidebar, session.content }) do
		local bindings = {
			{
				keymap = resolver.resolve("ui.close"),
				index = 101,
				callback = close,
			},
			{
				keymap = resolver.resolve("ui.help"),
				index = 100,
				callback = function()
					help.toggle({ buffer = pane.buf })
				end,
			},
		}

		for _, direction in ipairs({
			{ action = "ui.next_panel_tab", step = 1, index = 11 },
			{ action = "ui.previous_panel_tab", step = -1, index = 10 },
		}) do
			table.insert(bindings, {
				keymap = resolver.resolve(direction.action),
				index = direction.index,
				callback = function()
					local index = (session.sidebar.selected - 1 + direction.step) % #session.sidebar.pages + 1
					select_page(index)
				end,
			})
		end

		if pane == session.sidebar then
			table.insert(bindings, {
				keymap = resolver.resolve("ui.select"),
				index = 1,
				callback = function()
					select_page(vim.api.nvim_win_get_cursor(pane.win)[1])
					vim.api.nvim_set_current_win(session.content.win)
				end,
			})
		end

		local items = {}
		for _, binding in ipairs(bindings) do
			if binding.keymap then
				table.insert(items, {
					key = binding.keymap.key,
					desc = binding.keymap.desc,
					index = binding.index,
					callback = binding.callback,
					opts = { nowait = true, silent = true },
				})
			end
		end
		help.register("General", items, { buffer = pane.buf, index = 1 })
	end
end

---@param session RepositoryBrowser
---@param buf integer
---@return AtlasKeymapActionId[]
function M.hints(session, buf)
	if buf == session.sidebar.buf then
		return {
			"ui.select",
			"ui.next_panel_tab",
		}
	end

	return {
		"ui.select",
		"pulls.open_diff",
		"ui.open_actions",
		"ui.open_in_browser",
		"ui.next_panel_tab",
	}
end

return M
