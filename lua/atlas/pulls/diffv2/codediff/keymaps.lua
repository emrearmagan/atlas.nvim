local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@param view AtlasDiffV2View
---@param bindings AtlasDiffV2Keymaps
function M.setup(view, bindings)
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
