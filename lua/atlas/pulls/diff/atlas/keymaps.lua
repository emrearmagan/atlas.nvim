local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local help = require("atlas.ui.popups.help")
local picker = require("atlas.ui.picker")
local resolver = require("atlas.core.keymaps")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")

---@class AtlasNativeDiffKeymapActions
---@field close fun()
---@field reload fun()
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

---@param session AtlasDiffSession
---@param actions AtlasNativeDiffKeymapActions
function M.register(session, actions)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local run = function(callback)
		return guard(session, callback)
	end
	local find_file = run(function()
		local files = {}
		for index, file in ipairs(state.files) do
			files[index] = { index = index, path = file.path }
		end
		picker.find({
			title = "Changed files",
			items = files,
			initial_index = state.pending_index or state.selected_index,
			key = function(file)
				return file.path
			end,
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
	for _, buf in ipairs({ state.panel.buf, state.commits_panel.buf, state.left.buf, state.right.buf }) do
		local find_action = buf == state.panel.buf and "pulls.review.explorer.find_file" or "pulls.review.find_file"
		local find_item = item(find_action, {
			desc = "Find changed file",
			index = 7,
			callback = find_file,
			opts = { silent = true, nowait = true },
		})

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
					callback = run(actions.reload),
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
		reload = actions.reload,
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

return M
