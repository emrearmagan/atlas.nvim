local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param index integer
---@param callback fun()
local function add(items, action, desc, index, callback)
	local keys = resolver.resolve(action)
	if keys then
		items[#items + 1] = {
			key = keys,
			desc = desc,
			index = index,
			callback = callback,
			opts = { nowait = true, silent = true },
		}
	end
end

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
---@param actions { navigate_hunk: fun(direction: 1|-1), toggle_layout: fun(), toggle_compact: fun(), show_details: fun() }
function M.setup(session, bindings, actions)
	local view = session.view
	local view_items = {}
	add(view_items, "pulls.review.view.prev_hunk", "Previous hunk", 10, function()
		actions.navigate_hunk(-1)
	end)
	add(view_items, "pulls.review.view.next_hunk", "Next hunk", 11, function()
		actions.navigate_hunk(1)
	end)
	local help_items = {}
	add(help_items, "ui.help", "Toggle help", 100, help.toggle)
	vim.list_extend(view_items, help_items)
	local review_items = {}
	add(review_items, "pulls.review.show_details", "Show comments/notes", 35, actions.show_details)

	local layout_items = {}
	add(layout_items, "pulls.review.view.toggle_layout", "Toggle diff layout", 20, actions.toggle_layout)
	add(layout_items, "pulls.review.view.toggle_compact", "Toggle compact mode", 21, actions.toggle_compact)

	for _, group in ipairs(bindings.shared) do
		help.register(group.name, group.items, { buffer = session.explorer.buf, index = group.index })
	end
	help.register("Explorer", bindings.explorer_items, { buffer = session.explorer.buf })
	help.register("View", help_items, { buffer = session.explorer.buf })
	help.register("View", layout_items, { buffer = session.explorer.buf })

	help.register("View", layout_items, { buffer = session.commits.buf })

	for _, buf in ipairs({ view.left.buf, view.right.buf }) do
		for _, groups in ipairs({ bindings.shared, bindings.review }) do
			for _, group in ipairs(groups) do
				help.register(group.name, group.items, { buffer = buf, index = group.index })
			end
		end
		help.register("View", view_items, { buffer = buf })
		help.register("View", layout_items, { buffer = buf })
		help.register("Review", review_items, { buffer = buf, index = 3 })
	end
end

return M
