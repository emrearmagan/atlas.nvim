local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local help = require("atlas.ui.popups.help")
local picker = require("atlas.ui.picker")
local resolver = require("atlas.core.keymaps")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")

---@class AtlasNativeDiffKeymapActions
---@field close fun()
---@field reopen fun()
---@field refresh_review fun()
---@field toggle_layout fun()
---@field toggle_compact fun()
---@field navigate_hunk fun(direction: 1|-1)
---@field navigate_file fun(direction: 1|-1)
---@field navigate_unreviewed_file fun(direction: 1|-1)
---@field toggle_file_reviewed fun()
---@field toggle_explorer fun()
---@field toggle_commits fun()
---@field select_file fun(index: integer, focus_diff: boolean|nil)
---@field show_commit fun()
---@field add_file_comment fun(pending: boolean)

---@param action AtlasKeymapActionId
---@param definition AtlasHelpKeyItem
---@return AtlasHelpKeyItem|nil
local function item(action, definition)
	local keys = resolver.resolve(action)
	if not keys then
		return nil
	end
	definition.key = #keys == 1 and keys[1] or keys
	return definition
end

---@param items AtlasHelpKeyItem[]
---@param definition AtlasHelpKeyItem|nil
local function add(items, definition)
	if definition then
		items[#items + 1] = definition
	end
end

---@param session AtlasDiffSession
---@param callback fun()
---@return fun()
local function guard(session, callback)
	return function()
		if not session.closed and not session.viewer_state.closing and not help.is_open() then
			callback()
		end
	end
end

---@param actions AtlasNativeDiffKeymapActions
---@param run fun(callback: fun()): fun()
---@return AtlasHelpKeyItem[]
local function content_navigation(actions, run)
	local navigation = {}
	add(
		navigation,
		item("pulls.review.diff.previous_hunk", {
			desc = "Previous diff hunk",
			index = 1,
			callback = run(function()
				actions.navigate_hunk(-1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.diff.next_hunk", {
			desc = "Next diff hunk",
			index = 2,
			callback = run(function()
				actions.navigate_hunk(1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.explorer.previous_file", {
			desc = "Previous file",
			index = 3,
			callback = run(function()
				actions.navigate_file(-1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.explorer.next_file", {
			desc = "Next file",
			index = 4,
			callback = run(function()
				actions.navigate_file(1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.explorer.previous_unreviewed_file", {
			desc = "Previous unreviewed file",
			index = 5,
			callback = run(function()
				actions.navigate_unreviewed_file(-1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.explorer.next_unreviewed_file", {
			desc = "Next unreviewed file",
			index = 6,
			callback = run(function()
				actions.navigate_unreviewed_file(1)
			end),
			opts = { silent = true, nowait = true },
		})
	)

	return navigation
end

-- Registered per buffer so the head side can be re-bound when it swaps to a real worktree file.
---@param session AtlasDiffSession
---@param buf integer
---@param actions AtlasNativeDiffKeymapActions
function M.register_buffer(session, buf, actions)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local run = function(callback)
		return guard(session, callback)
	end
	local navigation = content_navigation(actions, run)
	local find_file = run(function()
		local files = {}
		for index, file in ipairs(state.files) do
			files[index] = { index = index, path = file.path }
		end
		picker.select({
			title = "Changed files",
			items = files,
			initial_index = state.pending_index or state.selected_index,
			format_item = function(file)
				return file.path
			end,
			on_select = function(file)
				if file then
					actions.select_file(file.index, true)
				end
			end,
		})
	end)
	local find_action = buf == state.panel.buf and "pulls.review.explorer.find_file" or "pulls.review.find_file"
	local find_item = item(find_action, {
		desc = "Find changed file",
		index = 7,
		callback = find_file,
		opts = { silent = true, nowait = true },
	})
	do
		local general = {}
		add(
			general,
			item("ui.close", {
				desc = buf == state.commits_panel.buf and "Close commits" or "Close diff",
				index = 1,
				callback = run(buf == state.commits_panel.buf and actions.toggle_commits or actions.close),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("ui.help", {
				desc = "Toggle help",
				index = 2,
				callback = run(function()
					help.toggle({ buffer = buf })
				end),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("ui.toggle_panel", {
				desc = "Toggle file explorer",
				index = 3,
				callback = run(actions.toggle_explorer),
				opts = { silent = true, nowait = true },
			})
		)
		if #session.commits > 0 then
			add(
				general,
				item("pulls.review.explorer.toggle_commits", {
					desc = "Toggle commits",
					index = 4,
					callback = run(actions.toggle_commits),
					opts = { silent = true, nowait = true },
				})
			)
		end
		add(
			general,
			item("pulls.review.diff.toggle_compact", {
				desc = "Toggle compact diff",
				index = 5,
				callback = run(actions.toggle_compact),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("pulls.review.diff.toggle_layout", {
				desc = "Toggle side-by-side / inline",
				index = 6,
				callback = run(actions.toggle_layout),
				opts = { silent = true, nowait = true },
			})
		)
		if buf == state.commits_panel.buf then
			if session.review then
				add(
					general,
					item("ui.refresh", {
						desc = "Refresh review",
						index = 7,
						callback = run(actions.refresh_review),
						opts = { silent = true, nowait = true },
					})
				)
			end
			add(
				general,
				item("ui.refresh_view", {
					desc = "Reload diff",
					index = 8,
					callback = run(actions.reopen),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				general,
				item("ui.show_details", {
					desc = "Show commit details",
					index = 9,
					callback = run(actions.show_commit),
					opts = { silent = true, nowait = true },
				})
			)
		end
		help.register("General", general, { index = 90, buffer = buf })
		if session.review and (buf == state.left.buf or buf == state.right.buf) then
			local review = {}
			add(
				review,
				item("pulls.review.explorer.toggle_file_reviewed", {
					desc = "Toggle file reviewed",
					index = 1,
					callback = run(actions.toggle_file_reviewed),
					opts = { silent = true, nowait = true },
				})
			)
			help.register("Review", review, { index = 110, buffer = buf })
		end
		help.register("Navigation", navigation, { index = 120, buffer = buf })
		if find_item then
			help.register("Navigation", { find_item }, { index = 120, buffer = buf })
		end
	end
end

---@param session AtlasDiffSession
---@param actions AtlasNativeDiffKeymapActions
function M.register(session, actions)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local run = function(callback)
		return guard(session, callback)
	end
	for _, buf in ipairs({ state.panel.buf, state.commits_panel.buf, state.left.buf, state.right.buf }) do
		M.register_buffer(session, buf, actions)
	end

	local panel_actions = {}
	add(
		panel_actions,
		item("ui.select", {
			desc = "Show changed file",
			index = 1,
			callback = run(function()
				local index = explorer.open_at_cursor(session)
				if index then
					actions.select_file(index)
				end
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("pulls.review.focus_item", {
			desc = "Focus changed file",
			index = 2,
			callback = run(function()
				local index = explorer.open_at_cursor(session)
				if index then
					actions.select_file(index, true)
				end
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("ui.show_details", {
			desc = "Show file path / item",
			index = 3,
			callback = run(function()
				explorer.show_path(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("pulls.review.explorer.toggle_grouping", {
			desc = "Toggle grouped / plain files",
			index = 4,
			callback = run(function()
				explorer.toggle_grouping(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("ui.toggle_fold", {
			desc = "Toggle folder",
			index = 5,
			callback = run(function()
				explorer.toggle_folder(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("ui.toggle_all_folds", {
			desc = "Toggle all folders",
			index = 6,
			callback = run(function()
				explorer.toggle_all_folders(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		panel_actions,
		item("pulls.review.explorer.toggle_file_reviewed", {
			desc = "Toggle file reviewed",
			index = 7,
			callback = run(actions.toggle_file_reviewed),
			opts = { silent = true, nowait = true },
		})
	)
	help.register("Explorer", panel_actions, { index = 80, buffer = state.panel.buf })

	local review_buffers = { state.panel.buf, state.left.buf, state.right.buf }
	if session.review_panel then
		review_buffers[#review_buffers + 1] = session.review_panel.buf
	end
	review_keymaps.register(session, {
		buffers = review_buffers,
		reopen = actions.reopen,
		file_buffers = { state.panel.buf },
		add_file_comment = actions.add_file_comment,
	})
	if session.review_panel then
		review_panel.register_toggle(session.review_panel, {
			state.panel.buf,
			state.commits_panel.buf,
			state.left.buf,
			state.right.buf,
		})
	end
end

-- Review mappings for a single buffer, for the same reason as `register_buffer`.
---@param session AtlasDiffSession
---@param buf integer
---@param reopen fun()|nil
function M.register_review_buffer(session, buf, reopen)
	review_keymaps.register(session, { buffers = { buf }, reopen = reopen })
end

-- Strip everything this session mapped on a content buffer. Worktree buffers are real files that
-- outlive the diff, so leaving `q` or `<CR>` bound on them would follow the user around.
---@param buf integer
function M.unregister_buffer(buf)
	if not buf then
		return
	end
	help.remove_buffer(buf)
end

return M
