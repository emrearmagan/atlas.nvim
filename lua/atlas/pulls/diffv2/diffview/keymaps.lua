local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
function M.setup(session, bindings)
	local view = session.view
	for _, group in ipairs(bindings.shared) do
		help.register(group.name, group.items, { buffer = session.explorer.buf, index = group.index })
	end
	help.register("Explorer", bindings.explorer_items, { buffer = session.explorer.buf })
	local explorer_help = resolver.resolve("ui.help")
	if explorer_help then
		help.register("View", {
			{
				key = explorer_help,
				desc = "Toggle help",
				index = 100,
				callback = help.toggle,
				opts = { nowait = true, silent = true },
			},
		}, { buffer = session.explorer.buf })
	end

	local help_keys = resolver.resolve("pulls.review.view.external_help")
	local items = {}
	if help_keys then
		items[#items + 1] = {
			key = help_keys,
			desc = "Toggle Atlas help",
			index = 100,
			callback = help.toggle,
			opts = { nowait = true, silent = true },
		}
	end

	for _, pane in pairs({ view.left, view.right }) do
		for _, groups in ipairs({ bindings.shared, bindings.review }) do
			for _, group in ipairs(groups) do
				help.register(group.name, group.items, { buffer = pane.buf, index = group.index })
			end
		end

		if help_keys then
			help.register("View", items, { buffer = pane.buf })
		end
	end
end

return M
