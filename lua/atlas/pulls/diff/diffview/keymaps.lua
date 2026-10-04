local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local diffview_actions = require("diffview.actions")
local config = require("diffview.config")
local resolver = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.diff.ui.explorer")
local help = require("atlas.ui.popups.help")

local M = {}

-- Diffview stores mappings as { mode, key, action, options }.
local function bind_native(buf, mappings, callbacks)
	for _, mapping in ipairs(mappings) do
		local mode, key, action, options = unpack(mapping)
		local callback = callbacks[action]
		if callback == nil then
			callback = action
		end

		if callback then
			local opts = vim.tbl_extend("force", options or {}, { buffer = buf, silent = true })
			vim.keymap.set(mode, key, callback, opts)
		end
	end
end

---@param session AtlasDiffSession
---@param commands AtlasDiffKeymapActions
---@param groups AtlasDiffKeymapGroup[]
function M.setup(session, commands, groups)
	local view = session.view
	---@cast view AtlasDiffDiffviewView
	local state = session.explorer
	local native_keys = config.get_config().keymaps

	-- Adapt this view's internal lookup so native file actions see our explorer selection.
	view.diffview.infer_cur_file = function(self, allow_dir)
		if vim.api.nvim_get_current_win() ~= state.win then
			return DiffView.infer_cur_file(self, allow_dir)
		end

		local file = explorer.current_file(state)
		if not file then
			return
		end
		for _, entry in self.files:iter() do
			if entry.path == file.path then
				return entry
			end
		end
	end

	-- Keep Diffview's configured keys, but route file navigation through Atlas's explorer.
	local navigation = {
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
		[diffview_actions.refresh_files] = commands.reload,
	}
	local shared = vim.tbl_extend("force", navigation, {
		[diffview_actions.close] = function()
			if not help.is_open() then
				commands.close()
			end
		end,
	})

	if session.data.pr then
		for _, mapping in ipairs(diffview_actions.compat.fold_cmds) do
			local _, command, fold = unpack(mapping)
			if command == "za" or command == "zA" then
				shared[fold] = function()
					if not commands.toggle_threads(command == "zA") and vim.fn.foldlevel(".") > 0 then
						fold()
					end
				end
			end
		end
	end

	-- Add more Diffview actions for Atlas's explorer here.
	local explorer_actions = vim.tbl_extend("force", shared, {
		-- Keep ordinary Vim movement, and leave staging out of a commit comparison.
		[diffview_actions.next_entry] = false,
		[diffview_actions.prev_entry] = false,
		[diffview_actions.toggle_stage_entry] = false,
		[diffview_actions.stage_all] = false,
		[diffview_actions.unstage_all] = false,
		[diffview_actions.restore_entry] = false,
		[diffview_actions.select_entry] = function()
			explorer.activate(state)
		end,
		[diffview_actions.listing_style] = function()
			explorer.toggle_view_mode(state)
		end,
		[diffview_actions.toggle_fold] = function()
			explorer.toggle_folder(state)
		end,
		[diffview_actions.open_fold] = function()
			explorer.set_folder_collapsed(state, false)
		end,
		[diffview_actions.close_fold] = function()
			explorer.set_folder_collapsed(state, true)
		end,
		[diffview_actions.open_all_folds] = function()
			explorer.set_all_folders_collapsed(state, false)
		end,
		[diffview_actions.close_all_folds] = function()
			explorer.set_all_folders_collapsed(state, true)
		end,
		[diffview_actions.toggle_flatten_dirs] = function()
			explorer.toggle_flatten_dirs(state)
		end,
	})
	bind_native(state.buf, native_keys.file_panel, explorer_actions)

	local details_keys = resolver.resolve("pulls.review.show_details")
	if details_keys then
		help.register("Explorer", {
			{
				key = details_keys,
				desc = "Show file details",
				index = 2,
				callback = function()
					explorer.show_details(state)
				end,
				opts = { nowait = true, silent = true },
			},
		}, { buffer = state.buf, index = 1 })
	end

	-- Diffview defines refresh in its file panel; use those keys in the other panes too.
	local refresh_keys = vim.tbl_filter(function(mapping)
		local _, _, action = unpack(mapping)
		return action == diffview_actions.refresh_files
	end, native_keys.file_panel)
	local commits_keys = vim.tbl_filter(function(mapping)
		local _, _, action = unpack(mapping)
		return navigation[action] ~= nil
	end, native_keys.view)
	bind_native(session.commits.buf, refresh_keys, navigation)
	bind_native(session.commits.buf, commits_keys, navigation)

	for _, pane in pairs({ view.left, view.right }) do
		if pane.win then
			bind_native(pane.buf, refresh_keys, navigation)
			bind_native(pane.buf, native_keys.view, shared)
			for _, group in ipairs(groups) do
				help.register(group.name, group.items, { buffer = pane.buf, index = group.index })
			end
		end
	end
end

return M
