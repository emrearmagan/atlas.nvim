local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param session RepositoryBrowser
---@param close fun()
---@param select_page fun(index: integer)
function M.setup(session, close, select_page)
	for _, pane in ipairs({ session.sidebar, session.content }) do
		help.register("General", {
			{
				key = resolver.resolve("ui.close") or {},
				desc = "Close repository",
				callback = close,
				opts = { nowait = true, silent = true },
			},
			{
				key = resolver.resolve("ui.help") or {},
				desc = "Toggle help",
				callback = function()
					help.toggle({ buffer = pane.buf })
				end,
				opts = { nowait = true, silent = true },
			},
		}, { buffer = pane.buf })

		local items = {}
		for _, direction in ipairs({
			{ "ui.next_panel_tab", "Next page", 1 },
			{ "ui.previous_panel_tab", "Previous page", -1 },
		}) do
			table.insert(items, {
				key = resolver.resolve(direction[1]) or {},
				desc = direction[2],
				callback = function()
					local index = (session.sidebar.selected - 1 + direction[3]) % #session.sidebar.pages + 1
					select_page(index)
				end,
				opts = { nowait = true, silent = true },
			})
		end
		if pane == session.sidebar then
			table.insert(items, {
				key = resolver.resolve("ui.select") or {},
				desc = "Open page",
				callback = function()
					select_page(vim.api.nvim_win_get_cursor(pane.win)[1])
					vim.api.nvim_set_current_win(session.content.win)
				end,
				opts = { nowait = true, silent = true },
			})
		end
		help.register("Pages", items, { buffer = pane.buf })
	end
end

return M
