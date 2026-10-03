local lifecycle = require("codediff.ui.lifecycle")
local codediff_keys = require("codediff.keymap.resolve")
local codediff_help = require("codediff.ui.keymap_help")
local compact = require("codediff.ui.view.compact")
local navigation = require("codediff.ui.view.navigation")
local explorer = require("atlas.pulls.diffv2.ui.explorer")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@param items AtlasHelpKeyItem[]
---@param keys string[]|false|nil
---@param desc string
---@param callback fun()
---@param index integer|nil
local function add(items, keys, desc, callback, index)
	if not keys then
		return
	end

	items[#items + 1] = {
		key = keys,
		desc = desc,
		index = index,
		callback = callback,
		opts = { nowait = true, silent = true },
	}
end

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
---@param toggle_layout fun()
---@return AtlasHelpKeyItem[]
local function setup_explorer(session, bindings, toggle_layout)
	local view = session.view
	local state = session.explorer
	local actions = bindings.actions
	local view_keys = codediff_keys.keymaps_for("view")
	local explorer_keys = codediff_keys.keymaps_for("explorer")

	-- These CodeDiff actions need to reach Atlas's explorer and track its panes.
	local shared_items = {}
	add(shared_items, view_keys.prev_file, "Previous file", function()
		actions.navigate_file(-1)
	end)
	add(shared_items, view_keys.next_file, "Next file", function()
		actions.navigate_file(1)
	end)
	add(shared_items, view_keys.toggle_explorer, "Toggle explorer", actions.toggle_explorer)
	add(shared_items, view_keys.focus_explorer, "Focus explorer", actions.focus_explorer)
	add(shared_items, view_keys.toggle_layout, "Toggle diff layout", toggle_layout)

	-- Add more CodeDiff keys for the Atlas explorer here.
	local items = {}
	add(items, explorer_keys.select, "Select file / toggle folder", function()
		explorer.activate(state)
	end)
	add(items, explorer_keys.hover, "Show file details", function()
		explorer.show_details(state)
	end)
	add(items, explorer_keys.toggle_view_mode, "Toggle explorer mode", function()
		explorer.toggle_view_mode(state)
	end)
	add(items, explorer_keys.fold_toggle, "Toggle folder", function()
		explorer.toggle_folder(state)
	end)
	add(items, view_keys.open_in_prev_tab, "Open local file", actions.open_file)
	add(items, view_keys.prev_hunk, "Previous hunk", function()
		vim.api.nvim_win_call(view.right.win, navigation.prev_hunk)
	end)
	add(items, view_keys.next_hunk, "Next hunk", function()
		vim.api.nvim_win_call(view.right.win, navigation.next_hunk)
	end)
	add(items, view_keys.toggle_compact, "Toggle compact mode", function()
		compact.toggle(view.tabpage)
	end)
	add(items, explorer_keys.refresh, "Reload the diff", actions.reload)
	add(items, view_keys.show_help, "Show CodeDiff help", function()
		codediff_help.toggle(view.tabpage)
	end)
	add(items, view_keys.quit, "Close review", function()
		if not help.is_open() then
			actions.close()
		end
	end)

	vim.list_extend(items, shared_items)
	for _, item in ipairs(items) do
		for _, key in ipairs(item.key) do
			vim.keymap.set(
				"n",
				key,
				item.callback,
				{ buffer = state.buf, desc = item.desc, nowait = true, silent = true }
			)
		end
	end
	return shared_items
end

---@param view AtlasDiffV2View
---@param buf integer
---@param items AtlasHelpKeyItem[]
local function bind_pane(view, buf, items)
	for _, item in ipairs(items) do
		local opts = vim.tbl_extend("force", item.opts or {}, { desc = item.desc })
		lifecycle.set_buf_keymap(view.tabpage, buf, item.mode or "n", item.key, item.callback, opts, { priority = 1 })
	end
end

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
---@param actions { toggle_layout: fun(), show_details: fun() }
function M.setup(session, bindings, actions)
	local view = session.view
	local shared_items = setup_explorer(session, bindings, actions.toggle_layout)
	local explorer_items = {}
	add(
		explorer_items,
		resolver.resolve("pulls.review.explorer.toggle_commits"),
		"Toggle commits",
		bindings.actions.toggle_commits,
		42
	)
	help.register("Explorer", explorer_items, { buffer = session.explorer.buf, index = 1 })

	local help_items = {}
	add(help_items, resolver.resolve("pulls.review.view.external_help"), "Toggle Atlas help", help.toggle)
	help.register("View", help_items, { buffer = session.explorer.buf, index = 2 })

	local review_items = {}
	add(review_items, resolver.resolve("pulls.review.show_details"), "Show comments/notes", actions.show_details, 35)

	local groups = {
		{ name = "Explorer", items = explorer_items, index = 1 },
		{ name = "View", items = help_items, index = 2 },
		{ name = "Review", items = review_items, index = 3 },
	}
	vim.list_extend(groups, bindings.review)

	-- CodeDiff sets its keys again after loading. Its registry keeps our Atlas keys in place.
	lifecycle.begin_keymap_scope(view.tabpage, "atlas")
	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			bind_pane(view, pane.buf, shared_items)
			for _, group in ipairs(groups) do
				bind_pane(view, pane.buf, group.items)

				local descriptions = vim.deepcopy(group.items)
				for _, item in ipairs(descriptions) do
					item.callback = nil
				end
				help.register(group.name, descriptions, { buffer = pane.buf, index = group.index })
			end
		end
	end
	lifecycle.end_keymap_scope(view.tabpage, "atlas")
end

return M
