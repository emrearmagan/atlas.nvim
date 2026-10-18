local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

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

---@param renderer AtlasDiffNativeRenderer
---@param viewer AtlasDiffViewer
---@param groups AtlasDiffKeymapGroup[]
function M.setup(renderer, viewer, groups)
	local explorer = viewer.explorer

	local navigation_items = {}
	add(navigation_items, "pulls.review.atlas.prev_file", "Previous file", 10, function()
		viewer:navigate_file(-1)
	end)
	add(navigation_items, "pulls.review.atlas.next_file", "Next file", 11, function()
		viewer:navigate_file(1)
	end)
	add(navigation_items, "pulls.review.atlas.toggle_explorer", "Toggle explorer", 40, function()
		viewer:toggle_explorer()
	end)
	add(navigation_items, "pulls.review.atlas.focus_explorer", "Focus explorer", 41, function()
		viewer:focus_explorer()
	end)

	local layout_items = {}
	add(layout_items, "pulls.review.atlas.toggle_layout", "Toggle diff layout", 60, function()
		renderer:toggle_layout()
	end)
	add(layout_items, "pulls.review.atlas.toggle_compact", "Toggle compact mode", 61, function()
		renderer:toggle_compact()
	end)
	add(layout_items, "ui.refresh_view", "Reload the diff", 80, function()
		viewer:reload()
	end)

	local file_items = {}
	add(file_items, "pulls.review.atlas.open_file", "Open local file", 31, function()
		viewer:open_file()
	end)
	local close_items = {}
	add(close_items, "ui.close", "Close review", 101, function()
		if not help.is_open() then
			viewer:close("user_close")
		end
	end)
	local explorer_items = {}
	add(explorer_items, "ui.select", "Select file / toggle folder", 1, function()
		explorer:activate()
	end)
	add(explorer_items, "pulls.review.show_details", "Show file details", 2, function()
		explorer:show_details()
	end)
	add(explorer_items, "pulls.review.atlas.toggle_view_mode", "Toggle explorer mode", 50, function()
		explorer:toggle_view_mode()
	end)
	add(explorer_items, "ui.toggle_fold", "Toggle folder", 51, function()
		explorer:toggle_folder()
	end)
	add(explorer_items, "ui.toggle_all_folds", "Toggle all folders", 52, function()
		explorer:toggle_all_folders()
	end)
	local hunk_items = {}
	add(hunk_items, "pulls.review.atlas.prev_hunk", "Previous hunk", 12, function()
		renderer:navigate_hunk(-1)
	end)
	add(hunk_items, "pulls.review.atlas.next_hunk", "Next hunk", 13, function()
		renderer:navigate_hunk(1)
	end)

	local thread_items = {}
	if renderer.session.source.kind == "pr" then
		add(thread_items, "ui.toggle_fold", "Toggle review thread / fold", 42, function()
			if not viewer:toggle_threads() and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! za")
			end
		end)
		add(thread_items, "ui.toggle_all_folds", "Toggle all review threads / folds", 43, function()
			if not viewer:toggle_threads(true) and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! zA")
			end
		end)
	end

	for buf, name in pairs({
		[explorer.buf] = "Explorer",
		[viewer.commits.buf] = "Commits",
		[renderer.left.buf] = "View",
		[renderer.right.buf] = "View",
	}) do
		help.register(name, navigation_items, { buffer = buf, index = 1 })
		help.register(name, layout_items, { buffer = buf })
		if buf ~= viewer.commits.buf then
			help.register(name, file_items, { buffer = buf })
			help.register(name, close_items, { buffer = buf })
		end
	end

	help.register("Explorer", explorer_items, { buffer = explorer.buf })
	for _, pane in pairs({ renderer.left, renderer.right }) do
		help.register("View", hunk_items, { buffer = pane.buf })
		help.register("Review", thread_items, { buffer = pane.buf, index = 2 })
		for _, group in ipairs(groups) do
			help.register(group.name, group.items, { buffer = pane.buf, index = group.index })
		end
	end
end

return M
