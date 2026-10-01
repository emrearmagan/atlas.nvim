local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

function M.setup(view, groups)
	local help_keys = resolver.resolve("pulls.review.view.external_help")
	for _, pane in pairs({ view.left, view.right }) do
		for index, group in ipairs(groups) do
			help.register(group.name, group.items, { buffer = pane.buf, index = index })
		end

		if help_keys then
			help.register("View", {
				{
					key = help_keys,
					desc = "Toggle Atlas help",
					callback = function()
						help.toggle({ buffer = pane.buf })
					end,
					opts = { nowait = true, silent = true },
				},
			}, { buffer = pane.buf })
		end
	end
end

return M
