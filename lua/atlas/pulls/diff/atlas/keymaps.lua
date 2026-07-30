local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

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
---@field toggle_file_reviewed fun()
---@field toggle_panel fun()
---@field toggle_commits fun()
---@field select_file fun(index: integer)
---@field refresh fun()
---@field open_item fun(buf: integer)
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
		item("pulls.review.previous_hunk", {
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
		item("pulls.review.next_hunk", {
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
		item("pulls.review.previous_file", {
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
		item("pulls.review.next_file", {
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
		session.footer.buf,
	}) do
		local general_actions = {}
		add(
			general_actions,
			item("ui.close", {
				desc = "Close diff",
				index = 1,
				callback = run(actions.close),
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
				index = 5,
				callback = run(actions.reload),
				opts = { silent = true, nowait = true },
			})
		)
		if #session.commits > 0 then
			add(
				general_actions,
				item("pulls.review.toggle_commits", {
					desc = "Toggle commits",
					index = 4,
					callback = run(actions.toggle_commits),
					opts = { silent = true, nowait = true },
				})
			)
		end
		if buf == session.commits_panel.buf then
			add(
				general_actions,
				item("ui.show_details", {
					desc = "Show details",
					index = 8,
					callback = run(actions.show_commit),
					opts = { silent = true, nowait = true },
				})
			)
		end
		add(
			general_actions,
			item("pulls.review.toggle_compact", {
				desc = "Toggle full / compact",
				index = 6,
				callback = run(actions.toggle_compact),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general_actions,
			item("pulls.review.toggle_layout", {
				desc = "Toggle side-by-side / inline",
				index = 7,
				callback = run(actions.toggle_layout),
				opts = { silent = true, nowait = true },
			})
		)
		local review_actions = {}
		if review_enabled then
			add(
				review_actions,
				item("ui.refresh", {
					desc = "Refresh comments and tasks",
					index = 1,
					callback = run(actions.refresh),
					opts = { silent = true, nowait = true },
				})
			)
		end
		if review_enabled and buf ~= session.commits_panel.buf then
			add(
				review_actions,
				item("pulls.review.toggle_file_reviewed", {
					desc = "Toggle file reviewed",
					index = 2,
					callback = run(actions.toggle_file_reviewed),
					opts = { silent = true, nowait = true },
				})
			)
		end
		if review_enabled and (buf == session.left.buf or buf == session.right.buf) then
			add(
				review_actions,
				item("pulls.review.view_thread", {
					desc = "Open comment thread",
					index = 3,
					callback = run(function()
						actions.open_item(buf)
					end),
					opts = { silent = true, nowait = true },
				})
			)
		end
		help.register("General", general_actions, { index = 90, buffer = buf })
		help.register("Review", review_actions, { index = 110, buffer = buf })
		help.register("Navigation", navigation, { index = 120, buffer = buf })
	end

	local explorer_actions = {
		{
			key = { "<CR>", "l" },
			desc = "Open changed file",
			index = 1,
			callback = run(function()
				local index = explorer.open_at_cursor(session)
				if index then
					actions.select_file(index)
				end
			end),
			opts = { silent = true, nowait = true },
		},
	}
	add(
		explorer_actions,
		item("ui.show_details", {
			desc = "Show file path / item",
			index = 2,
			callback = run(function()
				explorer.show_path(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	if session.explorer.grouped then
		add(
			explorer_actions,
			item("ui.toggle_fold", {
				desc = "Toggle folder",
				index = 3,
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
				index = 4,
				callback = run(function()
					explorer.toggle_all_folders(session)
				end),
				opts = { silent = true, nowait = true },
			})
		)
	end
	if not review_enabled then
		add(
			explorer_actions,
			item("pulls.review.toggle_file_reviewed", {
				desc = "Toggle file reviewed",
				index = 5,
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
	for _, buf in ipairs({ session.panel.buf, session.left.buf, session.right.buf }) do
		local review_actions = {}
		local navigation = {}
		if buf == session.panel.buf then
			if actions.toggle_task then
				add(
					review_actions,
					item("pulls.review.toggle_resolved", {
						desc = "Toggle task completion",
						index = 11,
						callback = run(actions.toggle_task),
						opts = { silent = true, nowait = true },
					})
				)
			end
		else
			add(
				review_actions,
				item("pulls.review.toggle_resolved", {
					desc = "Toggle resolved",
					index = 11,
					callback = run(function()
						actions.toggle_resolved(buf)
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				review_actions,
				item("pulls.review.add_pending_comment", {
					desc = "Add pending inline comment",
					index = 12,
					callback = run(function()
						actions.add_comment(buf, true)
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				review_actions,
				item("pulls.review.add_comment", {
					desc = "Add inline comment",
					index = 13,
					callback = run(function()
						actions.add_comment(buf, false)
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				review_actions,
				item("ui.toggle_fold", {
					desc = "Toggle review thread",
					index = 14,
					callback = run(function()
						if not actions.toggle_thread(buf) then
							pcall(vim.cmd.normal, { "za", bang = true })
						end
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				review_actions,
				item("ui.toggle_all_folds", {
					desc = "Toggle all review threads",
					index = 15,
					callback = run(function()
						if not actions.toggle_all_threads() then
							pcall(vim.cmd.normal, { "zA", bang = true })
						end
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				navigation,
				item("pulls.review.next_comment", {
					desc = "Next review comment",
					index = 6,
					callback = run(function()
						actions.jump_comment(buf, 1)
					end),
					opts = { silent = true, nowait = true },
				})
			)
			add(
				navigation,
				item("pulls.review.previous_comment", {
					desc = "Previous review comment",
					index = 5,
					callback = run(function()
						actions.jump_comment(buf, -1)
					end),
					opts = { silent = true, nowait = true },
				})
			)
		end
		add(
			review_actions,
			item("ui.open_in_browser", {
				desc = "Open pull request in browser",
				index = 16,
				callback = run(actions.open_in_browser),
				opts = { silent = true, nowait = true },
			})
		)
		help.register("Review", review_actions, { index = 110, buffer = buf })
		help.register("Navigation", navigation, { index = 120, buffer = buf })
	end
end

local REVIEW_PANEL_ACTIONS = {
	"pulls.review.toggle_resolved",
	"ui.open_in_browser",
}

local REVIEW_CONTENT_ACTIONS = {
	"pulls.review.toggle_resolved",
	"pulls.review.add_pending_comment",
	"pulls.review.add_comment",
	"ui.toggle_fold",
	"ui.toggle_all_folds",
	"ui.open_in_browser",
}

local REVIEW_NAVIGATION_ACTIONS = {
	"pulls.review.next_comment",
	"pulls.review.previous_comment",
}

---@param action AtlasKeymapActionId
---@return AtlasHelpKeyItem|nil
local function remove_item(action)
	local keys = resolver.resolve(action)
	if not keys then
		return nil
	end
	return { key = #keys == 1 and keys[1] or keys, desc = "" }
end

---@param session AtlasNativeDiffSession
function M.unregister_review(session)
	for _, buf in ipairs({ session.panel.buf, session.left.buf, session.right.buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			local actions = buf == session.panel.buf and REVIEW_PANEL_ACTIONS or REVIEW_CONTENT_ACTIONS
			local items = {}
			for _, action in ipairs(actions) do
				add(items, remove_item(action))
			end
			help.remove("Review", items, { buffer = buf })
			if buf ~= session.panel.buf then
				local navigation = {}
				for _, action in ipairs(REVIEW_NAVIGATION_ACTIONS) do
					add(navigation, remove_item(action))
				end
				help.remove("Navigation", navigation, { buffer = buf })
			end
		end
	end
end

return M
