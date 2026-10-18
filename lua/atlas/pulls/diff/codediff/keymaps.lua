local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local codediff_keys = require("codediff.keymap.resolve")
local codediff_help = require("codediff.ui.keymap_help")
local compact = require("codediff.ui.view.compact")
local navigation = require("codediff.ui.view.navigation")
local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

local M = {}

---@param items AtlasHelpKeyItem[]
---@param keys string[]|false|nil
---@param desc string
---@param callback fun()
---@param index integer|nil
local function add(items, keys, desc, callback, index)
	if keys then
		items[#items + 1] = { key = keys, desc = desc, callback = callback, index = index }
	end
end

---@param tabpage integer
---@param buf integer
---@param items AtlasHelpKeyItem[]
local function bind(tabpage, buf, items)
	for _, item in ipairs(items) do
		if item.callback then
			local opts = vim.tbl_extend(
				"force",
				{ nowait = true, silent = true },
				item.opts or {},
				{ desc = item.desc }
			)
			lifecycle.set_buf_keymap(tabpage, buf, item.mode or "n", item.key, item.callback, opts, {
				priority = 1,
			})
		end
	end
end

---@param tabpage integer
---@param buf integer
---@param groups AtlasDiffKeymapGroup[]
local function register(tabpage, buf, groups)
	for _, group in ipairs(groups) do
		bind(tabpage, buf, group.items)
		local descriptions = vim.deepcopy(group.items)
		for _, item in ipairs(descriptions) do
			item.callback = nil
		end
		help.register(group.name, descriptions, { buffer = buf, index = group.index })
	end
end

---@param buf integer
---@param items AtlasHelpKeyItem[]
local function bind_panel(buf, items)
	for _, item in ipairs(items) do
		for _, key in ipairs(item.key) do
			vim.keymap.set("n", key, item.callback, { buffer = buf, desc = item.desc, nowait = true, silent = true })
		end
	end
end

---@param renderer AtlasDiffCodeDiffRenderer
---@param viewer AtlasDiffViewer
---@param groups AtlasDiffKeymapGroup[]
function M.setup(renderer, viewer, groups)
	local explorer = viewer.explorer
	local view_keys = codediff_keys.keymaps_for("view")
	local explorer_keys = codediff_keys.keymaps_for("explorer")
	local help_items = {}
	add(help_items, resolver.resolve("pulls.review.view.external_help"), "Show CodeDiff help", function()
		codediff_help.toggle(renderer.tabpage)
	end, 101)

	local function navigate_file(direction)
		if not config.options.diff.cycle_next_file then
			local index = (explorer:current_index() or 1) + direction
			if index < 1 or index > #explorer.files then
				return
			end
		end
		viewer:navigate_file(direction)
	end

	-- Keep CodeDiff's configured keys while routing its explorer actions through Atlas.
	local shared = {}
	add(shared, view_keys.prev_file, "Previous file", function()
		navigate_file(-1)
	end)
	add(shared, view_keys.next_file, "Next file", function()
		navigate_file(1)
	end)
	add(shared, view_keys.toggle_explorer, "Toggle explorer", function()
		viewer:toggle_explorer()
	end)
	add(shared, view_keys.focus_explorer, "Focus explorer", function()
		viewer:focus_explorer()
	end)
	add(shared, view_keys.toggle_layout, "Toggle diff layout", function()
		renderer:toggle_layout()
	end)
	add(shared, explorer_keys.refresh, "Reload the diff", function()
		viewer:reload()
	end)

	local panels = {}
	add(panels, view_keys.open_in_prev_tab, "Open local file", function()
		viewer:open_file()
	end)
	add(panels, view_keys.prev_hunk, "Previous hunk", function()
		vim.api.nvim_win_call(renderer.right.win, navigation.prev_hunk)
	end)
	add(panels, view_keys.next_hunk, "Next hunk", function()
		vim.api.nvim_win_call(renderer.right.win, navigation.next_hunk)
	end)
	add(panels, view_keys.toggle_compact, "Toggle compact mode", function()
		compact.toggle(renderer.tabpage)
	end)

	local explorer_items = {}
	add(explorer_items, explorer_keys.select, "Select file / toggle folder", function()
		explorer:activate()
	end)
	add(explorer_items, explorer_keys.hover, "Show file details", function()
		explorer:show_details()
	end)
	add(explorer_items, explorer_keys.toggle_view_mode, "Toggle explorer mode", function()
		explorer:toggle_view_mode()
	end)
	add(explorer_items, explorer_keys.fold_toggle, "Toggle folder", function()
		explorer:toggle_folder()
	end)
	add(explorer_items, view_keys.quit, "Close review", function()
		if not help.is_open() then
			viewer:close("user_close")
		end
	end)

	local threads = {}
	if renderer.session.source.kind == "pr" then
		add(threads, explorer_keys.fold_toggle, "Toggle review thread / fold", function()
			if not viewer:toggle_threads() and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! za")
			end
		end)
		add(threads, explorer_keys.fold_toggle_recursive, "Toggle all review threads / folds", function()
			if not viewer:toggle_threads(true) and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! zA")
			end
		end)
	end

	-- Atlas owns these panels; CodeDiff's buffer cleanup must not remove their keys.
	for _, buf in ipairs({ explorer.buf, viewer.commits.buf }) do
		bind_panel(buf, shared)
		bind_panel(buf, panels)
	end
	bind_panel(explorer.buf, explorer_items)
	help.register("Explorer", help_items, { buffer = explorer.buf, index = 1 })

	-- The registry preserves both owners through CodeDiff's asynchronous keymap setup.
	lifecycle.begin_keymap_scope(renderer.tabpage, "atlas_navigation")
	for _, pane in pairs({ renderer.left, renderer.right }) do
		if pane.win then
			bind(renderer.tabpage, pane.buf, shared)
		end
	end
	lifecycle.end_keymap_scope(renderer.tabpage, "atlas_navigation")

	lifecycle.begin_keymap_scope(renderer.tabpage, "atlas_threads")
	for _, pane in pairs({ renderer.left, renderer.right }) do
		if pane.win then
			bind(renderer.tabpage, pane.buf, threads)
		end
	end
	lifecycle.end_keymap_scope(renderer.tabpage, "atlas_threads")

	lifecycle.begin_keymap_scope(renderer.tabpage, "atlas_review")
	for _, pane in pairs({ renderer.left, renderer.right }) do
		if pane.win then
			register(renderer.tabpage, pane.buf, { { name = "View", items = help_items, index = 1 } })
			register(renderer.tabpage, pane.buf, groups)
		end
	end
	lifecycle.end_keymap_scope(renderer.tabpage, "atlas_review")
end

return M
