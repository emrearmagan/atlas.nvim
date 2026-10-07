local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local codediff_keys = require("codediff.keymap.resolve")
local codediff_help = require("codediff.ui.keymap_help")
local compact = require("codediff.ui.view.compact")
local navigation = require("codediff.ui.view.navigation")
local resolver = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.diff.ui.explorer")
local help = require("atlas.ui.popups.help")

local M = {}

---@param items AtlasHelpKeyItem[]
---@param keys string[]|false|nil
---@param desc string
---@param callback fun()
local function add(items, keys, desc, callback)
	if keys then
		items[#items + 1] = { key = keys, desc = desc, callback = callback }
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

---@param session AtlasDiffSession
---@param commands AtlasDiffKeymapActions
---@param groups AtlasDiffKeymapGroup[]
---@param renderer_actions { toggle_layout: fun() }
function M.setup(session, commands, groups, renderer_actions)
	local view = session.view
	local state = session.explorer
	local view_keys = codediff_keys.keymaps_for("view")
	local explorer_keys = codediff_keys.keymaps_for("explorer")
	local help_items = {}
	add(help_items, resolver.resolve("pulls.review.view.external_help"), "Show CodeDiff help", function()
		codediff_help.toggle(view.tabpage)
	end)

	local function navigate_file(direction)
		if not config.options.diff.cycle_next_file then
			local index = (explorer.current_index(state) or 1) + direction
			if index < 1 or index > #state.files then
				return
			end
		end
		commands.navigate_file(direction)
	end

	-- Keep CodeDiff's configured keys while routing its explorer actions through Atlas.
	local shared = {}
	add(shared, view_keys.prev_file, "Previous file", function()
		navigate_file(-1)
	end)
	add(shared, view_keys.next_file, "Next file", function()
		navigate_file(1)
	end)
	add(shared, view_keys.toggle_explorer, "Toggle explorer", commands.toggle_explorer)
	add(shared, view_keys.focus_explorer, "Focus explorer", commands.focus_explorer)
	add(shared, view_keys.toggle_layout, "Toggle diff layout", renderer_actions.toggle_layout)
	add(shared, explorer_keys.refresh, "Reload the diff", commands.reload)

	local panels = {}
	add(panels, view_keys.open_in_prev_tab, "Open local file", commands.open_file)
	add(panels, view_keys.prev_hunk, "Previous hunk", function()
		vim.api.nvim_win_call(view.right.win, navigation.prev_hunk)
	end)
	add(panels, view_keys.next_hunk, "Next hunk", function()
		vim.api.nvim_win_call(view.right.win, navigation.next_hunk)
	end)
	add(panels, view_keys.toggle_compact, "Toggle compact mode", function()
		compact.toggle(view.tabpage)
	end)

	local explorer_items = {}
	add(explorer_items, explorer_keys.select, "Select file / toggle folder", function()
		explorer.activate(state)
	end)
	add(explorer_items, explorer_keys.hover, "Show file details", function()
		explorer.show_details(state)
	end)
	add(explorer_items, explorer_keys.toggle_view_mode, "Toggle explorer mode", function()
		explorer.toggle_view_mode(state)
	end)
	add(explorer_items, explorer_keys.fold_toggle, "Toggle folder", function()
		explorer.toggle_folder(state)
	end)
	add(explorer_items, view_keys.quit, "Close review", function()
		if not help.is_open() then
			commands.close()
		end
	end)

	local threads = {}
	if session.data.pr then
		add(threads, explorer_keys.fold_toggle, "Toggle review thread / fold", function()
			if not commands.toggle_threads() and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! za")
			end
		end)
		add(threads, explorer_keys.fold_toggle_recursive, "Toggle all review threads / folds", function()
			if not commands.toggle_threads(true) and vim.fn.foldlevel(".") > 0 then
				vim.cmd("normal! zA")
			end
		end)
	end

	-- Atlas owns these panels; CodeDiff's buffer cleanup must not remove their keys.
	for _, buf in ipairs({ state.buf, session.commits.buf }) do
		bind_panel(buf, shared)
		bind_panel(buf, panels)
	end
	bind_panel(state.buf, explorer_items)
	help.register("Explorer", help_items, { buffer = state.buf, index = 1 })

	-- The registry preserves both owners through CodeDiff's asynchronous keymap setup.
	lifecycle.begin_keymap_scope(view.tabpage, "atlas_navigation")
	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			bind(view.tabpage, pane.buf, shared)
		end
	end
	lifecycle.end_keymap_scope(view.tabpage, "atlas_navigation")

	lifecycle.begin_keymap_scope(view.tabpage, "atlas_threads")
	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			bind(view.tabpage, pane.buf, threads)
		end
	end
	lifecycle.end_keymap_scope(view.tabpage, "atlas_threads")

	lifecycle.begin_keymap_scope(view.tabpage, "atlas_review")
	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			register(view.tabpage, pane.buf, { { name = "View", items = help_items, index = 1 } })
			register(view.tabpage, pane.buf, groups)
		end
	end
	lifecycle.end_keymap_scope(view.tabpage, "atlas_review")
end

return M
