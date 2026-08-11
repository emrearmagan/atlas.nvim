local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local review_keymaps = require("atlas.pulls.diff.shared.keymaps")

---@param action AtlasKeymapActionId
---@param map_item AtlasHelpKeyItem
---@return AtlasHelpKeyItem|nil
local function item(action, map_item)
	local keys = resolver.resolve(action)
	if not keys then
		return nil
	end
	map_item.key = #keys == 1 and keys[1] or keys
	return map_item
end

---@param items AtlasHelpKeyItem[]
---@param value AtlasHelpKeyItem|nil
local function add(items, value)
	if value then
		table.insert(items, value)
	end
end

---@param active fun(): boolean
---@param callback fun()
---@return fun()
local function guard(active, callback)
	return function()
		if active() and not help.is_open() then
			callback()
		end
	end
end

---@class AtlasDiffKeymapActions
---@field active fun(): boolean
---@field close fun()
---@field toggle_layout fun()
---@field toggle_compact fun()
---@field reload fun()
---@field navigate_hunk fun(direction: 1|-1)
---@field navigate_file fun(direction: 1|-1)
---@field navigate_unreviewed_file fun(direction: 1|-1)
---@field toggle_file_reviewed fun()
---@field toggle_panel fun()
---@field toggle_commits fun()
---@field toggle_review_panel fun()
---@field select_file fun(index: integer, focus_diff: boolean|nil)
---@field show_commit fun()

---@param session AtlasNativeDiffSession
---@param actions AtlasDiffKeymapActions
function M.register(session, actions)
	local review_enabled = session.review_context ~= nil
	local run = function(callback)
		return guard(actions.active, callback)
	end
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
	for _, buf in ipairs({
		session.panel.buf,
		session.commits_panel.buf,
		session.left.buf,
		session.right.buf,
	}) do
		local general_actions = {}
		add(
			general_actions,
			item("ui.close", {
				desc = buf == session.commits_panel.buf and "Close commits" or "Close diff",
				index = 1,
				callback = run(buf == session.commits_panel.buf and actions.toggle_commits or actions.close),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general_actions,
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
			general_actions,
			item("ui.toggle_panel", {
				desc = "Toggle file explorer",
				index = 3,
				callback = run(actions.toggle_panel),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general_actions,
			item("ui.refresh_view", {
				desc = review_enabled and "Reload pull request diff" or "Reload diff",
				index = 6,
				callback = run(actions.reload),
				opts = { silent = true, nowait = true },
			})
		)
		if #session.commits > 0 then
			add(
				general_actions,
				item("pulls.review.explorer.toggle_commits", {
					desc = "Toggle commits",
					index = 4,
					callback = run(actions.toggle_commits),
					opts = { silent = true, nowait = true },
				})
			)
		end
		if review_enabled then
			add(
				general_actions,
				item("pulls.review.diff.toggle_review_panel", {
					desc = "Toggle review panel",
					index = 5,
					callback = run(actions.toggle_review_panel),
					opts = { silent = true, nowait = true },
				})
			)
		end
		if buf == session.commits_panel.buf then
			add(
				general_actions,
				item("ui.show_details", {
					desc = "Show details",
					index = 9,
					callback = run(actions.show_commit),
					opts = { silent = true, nowait = true },
				})
			)
		end
		add(
			general_actions,
			item("pulls.review.diff.toggle_compact", {
				desc = "Toggle full / compact",
				index = 7,
				callback = run(actions.toggle_compact),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general_actions,
			item("pulls.review.diff.toggle_layout", {
				desc = "Toggle side-by-side / inline",
				index = 8,
				callback = run(actions.toggle_layout),
				opts = { silent = true, nowait = true },
			})
		)
		local review_actions = {}
		if review_enabled and buf ~= session.commits_panel.buf then
			add(
				review_actions,
				item("pulls.review.explorer.toggle_file_reviewed", {
					desc = "Toggle file reviewed",
					index = 2,
					callback = run(actions.toggle_file_reviewed),
					opts = { silent = true, nowait = true },
				})
			)
		end
		help.register("General", general_actions, { index = 90, buffer = buf })
		help.register("Review", review_actions, { index = 110, buffer = buf })
		help.register("Navigation", navigation, { index = 120, buffer = buf })
	end

	local explorer_actions = {}
	add(
		explorer_actions,
		item("pulls.review.explorer.focus_file", {
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
		explorer_actions,
		item("pulls.review.explorer.open_file", {
			desc = "Open changed file",
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
		explorer_actions,
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
		explorer_actions,
		item("pulls.review.explorer.toggle_grouping", {
			desc = "Toggle grouped / plain files",
			index = 3,
			callback = run(function()
				explorer.toggle_grouping(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		explorer_actions,
		item("ui.toggle_fold", {
			desc = "Toggle folder",
			index = 4,
			callback = run(function()
				explorer.toggle_folder(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		explorer_actions,
		item("ui.toggle_all_folds", {
			desc = "Toggle all folders",
			index = 5,
			callback = run(function()
				explorer.toggle_all_folders(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	if not review_enabled then
		add(
			explorer_actions,
			item("pulls.review.explorer.toggle_file_reviewed", {
				desc = "Toggle file reviewed",
				index = 6,
				callback = run(actions.toggle_file_reviewed),
				opts = { silent = true, nowait = true },
			})
		)
	end
	help.register("Explorer", explorer_actions, { index = 80, buffer = session.panel.buf })
end

---@param session AtlasNativeDiffSession
---@param actions AtlasReviewKeymapActions
function M.register_review(session, actions)
	local run = function(callback)
		return guard(actions.active, callback)
	end
	for _, buf in ipairs({
		session.panel.buf,
		session.commits_panel.buf,
		session.left.buf,
		session.right.buf,
		session.review_panel and session.review_panel.buf,
	}) do
		local groups = review_keymaps.groups(session, actions, buf, {
			include_actions = buf ~= session.commits_panel.buf,
			include_task = buf == session.panel.buf,
		})
		for _, group in ipairs(groups) do
			local items = {}
			for _, definition in ipairs(group.items) do
				add(
					items,
					item(definition.action, {
						desc = definition.desc,
						index = definition.index,
						callback = run(definition.callback),
						opts = { silent = true, nowait = true },
					})
				)
			end
			help.register(group.name, items, { index = group.index, buffer = buf })
		end
	end
end

return M
