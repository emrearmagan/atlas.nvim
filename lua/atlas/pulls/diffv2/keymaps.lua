local resolver = require("atlas.core.keymaps")
local commits = require("atlas.pulls.diffv2.ui.commits")
local explorer = require("atlas.pulls.diffv2.ui.explorer")
local help = require("atlas.ui.popups.help")

local M = {}

---@class AtlasDiffV2KeymapGroup
---@field name string
---@field items AtlasHelpKeyItem[]
---@field index integer

---@class AtlasDiffV2Keymaps
---@field shared AtlasDiffV2KeymapGroup[]
---@field review AtlasDiffV2KeymapGroup[]
---@field explorer_items AtlasHelpKeyItem[]
---@field actions AtlasDiffV2KeymapActions

---@class AtlasDiffV2KeymapActions
---@field close fun()
---@field reload fun()
---@field toggle_explorer fun()
---@field toggle_commits fun()
---@field toggle_review_panel fun()
---@field toggle_file_reviewed fun()
---@field toggle_resolved fun()
---@field delete_annotation fun()
---@field toggle_comments fun()
---@field focus_explorer fun()
---@field navigate_file fun(direction: 1|-1, unreviewed_only?: boolean)
---@field find_file fun()
---@field open_file fun()
---@field open_commit fun()
---@field add_comment fun(pending: boolean, suggestion?: boolean)
---@field add_note fun()
---@field navigate_annotation fun(direction: 1|-1, kind: "comment"|"note")
---@field dispatch fun(id: AtlasReviewActionId)
---@field run_custom fun(callback: fun(context: AtlasPullActionContext, done: fun(result: PullsActionResult|nil, err: string|nil)): any): any

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param index integer
---@param callback fun()
---@param mode string|string[]|nil
local function add(items, action, desc, index, callback, mode)
	local keys = resolver.resolve(action)
	if keys then
		items[#items + 1] = {
			key = keys,
			desc = desc,
			index = index,
			callback = callback,
			mode = mode,
			opts = { nowait = true, silent = true },
		}
	end
end

---@param actions AtlasDiffV2KeymapActions
---@return AtlasHelpKeyItem[], AtlasHelpKeyItem[]
local function shared_items(actions)
	local explorer_items = {}
	add(explorer_items, "pulls.review.explorer.prev_file", "Previous file", 10, function()
		actions.navigate_file(-1)
	end)
	add(explorer_items, "pulls.review.explorer.next_file", "Next file", 11, function()
		actions.navigate_file(1)
	end)
	add(explorer_items, "pulls.review.explorer.prev_unreviewed_file", "Previous unreviewed file", 20, function()
		actions.navigate_file(-1, true)
	end)
	add(explorer_items, "pulls.review.explorer.next_unreviewed_file", "Next unreviewed file", 21, function()
		actions.navigate_file(1, true)
	end)
	add(explorer_items, "pulls.review.explorer.find_file", "Find changed file", 30, actions.find_file)
	add(explorer_items, "pulls.review.explorer.toggle_explorer", "Toggle explorer", 40, actions.toggle_explorer)
	add(explorer_items, "pulls.review.explorer.focus_explorer", "Focus explorer", 41, actions.focus_explorer)
	add(explorer_items, "pulls.review.explorer.toggle_commits", "Toggle commits", 42, actions.toggle_commits)

	local view_items = {}
	add(view_items, "ui.refresh_view", "Reload the diff", 50, actions.reload)

	return explorer_items, view_items
end

---@param session AtlasDiffV2Session
---@param actions AtlasDiffV2KeymapActions
function M.setup(session, actions)
	local navigation_items, view_items = shared_items(actions)
	local shared_explorer_items = vim.list_extend({}, navigation_items)
	add(shared_explorer_items, "pulls.review.explorer.open_file", "Open local file", 31, actions.open_file)

	local commits_view_items = vim.list_extend({}, view_items)
	add(commits_view_items, "ui.help", "Toggle help", 100, help.toggle)
	add(view_items, "ui.close", "Close review", 101, function()
		if not help.is_open() then
			actions.close()
		end
	end)

	local review_items = {}
	local review_view_items = {}
	local has_review = session.data.review and session.data.review.data
	local shared = {
		{ name = "Explorer", items = shared_explorer_items, index = 1 },
		{ name = "View", items = view_items, index = 2 },
	}
	local review = {
		{ name = "View", items = review_view_items, index = 2 },
		{ name = "Review", items = review_items, index = 3 },
	}
	add(
		review_view_items,
		"pulls.review.view.toggle_review_panel",
		"Toggle review panel",
		41,
		actions.toggle_review_panel
	)
	add(review_view_items, "pulls.review.view.toggle_detail_panel", "Toggle PR details", 42, function()
		actions.dispatch("toggle_detail_panel")
	end)
	add(review_view_items, "pulls.review.view.toggle_comments", "Toggle comment display", 43, actions.toggle_comments)
	if session.data.pr then
		add(view_items, "ui.open_in_browser", "Open in browser", 51, function()
			actions.dispatch("open_in_browser")
		end)
	end
	if session.data.review then
		add(review_items, "pulls.review.toggle_file_reviewed", "Toggle file reviewed", 2, actions.toggle_file_reviewed)
	end
	if has_review then
		add(review_items, "ui.open_actions", "Review actions", 1, function()
			actions.dispatch("open_actions")
		end)
		add(review_items, "pulls.review.prev_comment", "Previous comment", 90, function()
			actions.navigate_annotation(-1, "comment")
		end)
		add(review_items, "pulls.review.next_comment", "Next comment", 91, function()
			actions.navigate_annotation(1, "comment")
		end)
		add(review_items, "pulls.review.approve", "Approve", 60, function()
			actions.dispatch("approve")
		end)
		add(review_items, "pulls.review.request_changes", "Request changes", 61, function()
			actions.dispatch("request_changes")
		end)
		add(review_items, "pulls.review.submit_review", "Submit review", 62, function()
			actions.dispatch("submit_review")
		end)
		vim.list_extend(review_items, resolver.custom_items("pulls", actions.run_custom))
	end
	if session.data.notes then
		add(review_items, "pulls.review.prev_note", "Previous note", 92, function()
			actions.navigate_annotation(-1, "note")
		end)
		add(review_items, "pulls.review.next_note", "Next note", 93, function()
			actions.navigate_annotation(1, "note")
		end)
	end

	local explorer_items = {}
	add(explorer_items, "ui.select", "Select file / toggle folder", 1, function()
		explorer.activate(session.explorer)
	end)
	add(explorer_items, "pulls.review.show_details", "Show file details", 2, function()
		explorer.show_details(session.explorer)
	end)

	add(explorer_items, "pulls.review.explorer.toggle_view_mode", "Toggle explorer mode", 50, function()
		explorer.toggle_view_mode(session.explorer)
	end)
	add(explorer_items, "ui.toggle_fold", "Toggle folder", 51, function()
		explorer.toggle_folder(session.explorer)
	end)
	add(explorer_items, "ui.toggle_all_folds", "Toggle all folders", 52, function()
		explorer.toggle_all_folders(session.explorer)
	end)

	local file_comment_items = {}
	if has_review then
		add(file_comment_items, "pulls.review.add_comment", "Add pending file comment", 60, function()
			actions.add_comment(true)
		end)
		add(file_comment_items, "pulls.review.submit_comment", "Post file comment", 61, function()
			actions.add_comment(false)
		end)
	end
	local commits_items = {}
	add(commits_items, "ui.close", "Close commits", 101, function()
		if not help.is_open() then
			actions.toggle_commits()
		end
	end)
	add(commits_items, "pulls.open_diff", "Open commit diff", 1, actions.open_commit)
	add(commits_items, "ui.copy_id", "Copy commit hash", 3, function()
		commits.copy_hash(session.commits)
	end)
	add(commits_items, "ui.open_in_browser", "Open commit in browser", 4, function()
		commits.open_in_browser(session.commits)
	end)
	add(commits_items, "pulls.review.show_details", "Show commit details", 2, function()
		commits.show_details(session.commits)
	end)

	-- These actions need a line in the diff.
	local diff_review_items = vim.list_extend({}, review_items)
	local diff_view_items = vim.list_extend({}, review_view_items)
	if has_review or session.data.notes then
		add(diff_review_items, "pulls.review.toggle_resolved", "Toggle resolved", 40, actions.toggle_resolved)
		add(diff_review_items, "ui.delete", "Delete comment / note", 41, actions.delete_annotation)
	end
	if has_review then
		add(diff_view_items, "pulls.review.add_comment", "Add pending line/selection comment", 30, function()
			actions.add_comment(true)
		end, { "n", "x" })
		add(diff_view_items, "pulls.review.submit_comment", "Post line/selection comment", 31, function()
			actions.add_comment(false)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.add_suggestion", "Add pending suggestion", 32, function()
			actions.add_comment(true, true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_suggestion", "Post suggestion", 33, function()
			actions.add_comment(false, true)
		end, { "n", "x" })
	end
	if session.data.notes then
		add(diff_review_items, "pulls.review.add_note", "Add note", 34, actions.add_note, { "n", "x" })
	end

	vim.list_extend(commits_view_items, review_view_items)
	for _, group in ipairs({
		{ name = "Explorer", items = navigation_items, index = 1 },
		{ name = "View", items = commits_view_items, index = 2 },
		{ name = "Review", items = review_items, index = 3 },
		{ name = "Commits", items = commits_items, index = 0 },
	}) do
		help.register(group.name, group.items, { buffer = session.commits.buf, index = group.index })
	end

	session.renderer.setup_keymaps(session, {
		shared = shared,
		review = {
			{ name = "View", items = diff_view_items, index = 2 },
			{ name = "Review", items = diff_review_items, index = 3 },
		},
		explorer_items = explorer_items,
		actions = actions,
	})
	for _, group in ipairs(review) do
		help.register(group.name, group.items, { buffer = session.explorer.buf, index = group.index })
	end
	help.register("Explorer", file_comment_items, { buffer = session.explorer.buf })
end

return M
