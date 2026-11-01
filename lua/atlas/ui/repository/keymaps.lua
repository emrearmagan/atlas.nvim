local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param session RepositoryBrowser
---@param close fun()
---@param select_page fun(index: integer)
function M.setup(session, close, select_page)
	for _, pane in ipairs({ session.sidebar, session.content }) do
		local items = {
			{
				key = resolver.resolve("ui.close") or {},
				desc = "Close repository",
				index = 101,
				callback = close,
				opts = { nowait = true, silent = true },
			},
			{
				key = resolver.resolve("ui.help") or {},
				desc = "Toggle help",
				index = 100,
				callback = function()
					help.toggle({ buffer = pane.buf })
				end,
				opts = { nowait = true, silent = true },
			},
		}

		for _, direction in ipairs({
			{ action = "ui.next_panel_tab", desc = "Next page", step = 1, index = 11 },
			{ action = "ui.previous_panel_tab", desc = "Previous page", step = -1, index = 10 },
		}) do
			table.insert(items, {
				key = resolver.resolve(direction.action) or {},
				desc = direction.desc,
				index = direction.index,
				callback = function()
					local index = (session.sidebar.selected - 1 + direction.step) % #session.sidebar.pages + 1
					select_page(index)
				end,
				opts = { nowait = true, silent = true },
			})
		end

		if pane == session.sidebar then
			table.insert(items, {
				key = resolver.resolve("ui.select") or {},
				desc = "Open page",
				index = 1,
				callback = function()
					select_page(vim.api.nvim_win_get_cursor(pane.win)[1])
					vim.api.nvim_set_current_win(session.content.win)
				end,
				opts = { nowait = true, silent = true },
			})
		end

		help.register("General", items, { buffer = pane.buf, index = 1 })
	end
end

return M
