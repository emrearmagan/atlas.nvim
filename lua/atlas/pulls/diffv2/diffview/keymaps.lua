local diffview_actions = require("diffview.actions")
local config = require("diffview.config")
local resolver = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.diffv2.ui.explorer")
local help = require("atlas.ui.popups.help")

local M = {}

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param callback fun()
---@param index integer|nil
local function add(items, action, desc, callback, index)
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

local function bind_native(buf, mappings, callbacks)
	for _, mapping in ipairs(mappings) do
		local callback = callbacks[mapping[3]]
		if callback then
			local opts = vim.tbl_extend("force", mapping[4] or {}, { buffer = buf, silent = true })
			vim.keymap.set(mapping[1], mapping[2], callback, opts)
		end
	end
end

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
---@param actions { show_details: fun() }
function M.setup(session, bindings, actions)
	local view = session.view
	local state = session.explorer
	local commands = bindings.actions
	local native_keys = config.get_config().keymaps

	-- Keep Diffview's configured keys, but route file navigation through Atlas's explorer.
	local shared = {
		[diffview_actions.select_prev_entry] = function()
			commands.navigate_file(-1)
		end,
		[diffview_actions.select_next_entry] = function()
			commands.navigate_file(1)
		end,
		[diffview_actions.select_first_entry] = function()
			if state.files[1] then
				state.on_select(state.files[1])
			end
		end,
		[diffview_actions.select_last_entry] = function()
			if state.files[#state.files] then
				state.on_select(state.files[#state.files])
			end
		end,
		[diffview_actions.focus_files] = commands.focus_explorer,
		[diffview_actions.toggle_files] = commands.toggle_explorer,
		[diffview_actions.goto_file_edit] = commands.open_file,
		[diffview_actions.close] = function()
			if not help.is_open() then
				commands.close()
			end
		end,
	}

	-- Add more Diffview actions for Atlas's explorer here.
	local explorer_actions = vim.tbl_extend("force", shared, {
		[diffview_actions.select_entry] = function()
			explorer.activate(state)
		end,
		[diffview_actions.listing_style] = function()
			explorer.toggle_view_mode(state)
		end,
		[diffview_actions.toggle_fold] = function()
			explorer.toggle_folder(state)
		end,
		[diffview_actions.refresh_files] = commands.reload,
		[diffview_actions.cycle_layout] = diffview_actions.cycle_layout,
		[diffview_actions.goto_file_split] = diffview_actions.goto_file_split,
		[diffview_actions.goto_file_tab] = diffview_actions.goto_file_tab,
	})
	local native_help = config.find_help_keymap(native_keys.file_panel)
	if native_help then
		explorer_actions[native_help[3]] = native_help[3]
	end
	bind_native(state.buf, native_keys.file_panel, explorer_actions)

	local explorer_items = {}
	add(explorer_items, "pulls.review.explorer.toggle_commits", "Toggle commits", commands.toggle_commits, 42)
	help.register("Explorer", explorer_items, { buffer = state.buf, index = 1 })

	local help_items = {}
	add(help_items, "pulls.review.view.external_help", "Toggle Atlas help", help.toggle)
	help.register("View", help_items, { buffer = state.buf, index = 2 })

	local details = {}
	add(details, "pulls.review.show_details", "Show file details", function()
		explorer.show_details(state)
	end, 2)
	help.register("Explorer", details, { buffer = state.buf, index = 1 })

	local review_items = {}
	add(review_items, "pulls.review.show_details", "Show comments/notes", actions.show_details, 35)
	local groups = {
		{ name = "Explorer", items = explorer_items, index = 1 },
		{ name = "View", items = help_items, index = 2 },
		{ name = "Review", items = review_items, index = 3 },
	}
	vim.list_extend(groups, bindings.review)

	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			bind_native(pane.buf, native_keys.view, shared)
			for _, group in ipairs(groups) do
				help.register(group.name, group.items, { buffer = pane.buf, index = group.index })
			end
		end
	end
end

return M
