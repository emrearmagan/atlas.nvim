local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")
local navigation = require("atlas.ui.repository.navigation")

local M = {}

---@param session RepositoryBrowser
---@param close fun()
---@param select_page fun(index: integer)
function M.setup(session, close, select_page)
	local nav = session.navigation
	for _, pane in ipairs({ nav, session.content }) do
		local items = {
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
		}
		for _, direction in ipairs({
			{ "ui.next_panel_tab", "Next page", 1 },
			{ "ui.previous_panel_tab", "Previous page", -1 },
		}) do
			table.insert(items, {
				key = resolver.resolve(direction[1]) or {},
				desc = direction[2],
				callback = function()
					local index = (nav.selected - 1 + direction[3]) % #nav.pages + 1
					select_page(index)
				end,
				opts = { nowait = true, silent = true },
			})
		end
		if pane == nav then
			table.insert(items, {
				key = resolver.resolve("ui.select") or {},
				desc = "Open page",
				callback = function()
					local index = navigation.index_at_cursor(nav)
					if index then
						select_page(index)
						vim.api.nvim_set_current_win(session.content.win)
					end
				end,
				opts = { nowait = true, silent = true },
			})
			for _, direction in ipairs({
				{ { "h", "<Left>" }, "Previous page", -1 },
				{ { "l", "<Right>" }, "Next page", 1 },
			}) do
				table.insert(items, {
					key = direction[1],
					desc = direction[2],
					callback = function()
						select_page((nav.selected - 1 + direction[3]) % #nav.pages + 1)
					end,
					opts = { nowait = true, silent = true },
				})
			end
		end
		vim.keymap.set("n", "<LeftMouse>", function()
			local mouse = vim.fn.getmousepos()
			if mouse.winid == nav.win and mouse.line > 0 and mouse.column > 0 then
				vim.schedule(function()
					if session.closed then
						return
					end
					vim.api.nvim_win_set_cursor(nav.win, { mouse.line, mouse.column - 1 })
					local index = navigation.index_at_cursor(nav)
					if index then
						select_page(index)
						vim.api.nvim_set_current_win(session.content.win)
					end
				end)
			end
			return "<LeftMouse>"
		end, { buffer = pane.buf, expr = true, silent = true })
		help.register("General", items, { buffer = pane.buf })
	end
end

return M
