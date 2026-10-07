local resolver = require("atlas.core.keymaps")
local commits = require("atlas.pulls.diff.ui.commits")
local help = require("atlas.ui.popups.help")

local M = {}

local shared_actions = {
	"ui.help",
	"ui.open_actions",
	"ui.open_in_browser",
	"ui.refresh",
	"pulls.review.toggle_file_reviewed",
	"pulls.review.next_comment",
	"pulls.review.prev_comment",
	"pulls.review.next_note",
	"pulls.review.prev_note",
	"pulls.review.add_comment",
	"pulls.review.submit_comment",
	"pulls.review.approve",
	"pulls.review.request_changes",
	"pulls.review.submit_review",
	"pulls.review.view.external_help",
	"pulls.review.view.toggle_review_panel",
	"pulls.review.view.toggle_detail_panel",
	"pulls.review.view.toggle_comments",
	"pulls.review.explorer.toggle_commits",
	"pulls.review.explorer.next_unreviewed_file",
	"pulls.review.explorer.prev_unreviewed_file",
	"pulls.review.explorer.find_file",
}

M.action_ids = {
	view = vim.list_extend({
		"ui.delete",
		"pulls.review.show_details",
		"pulls.review.add_suggestion",
		"pulls.review.submit_suggestion",
		"pulls.review.add_note",
		"pulls.review.toggle_resolved",
	}, shared_actions),
	explorer = shared_actions,
}

---@class AtlasDiffKeymapGroup
---@field name string
---@field items AtlasHelpKeyItem[]
---@field index integer

---@class AtlasDiffKeymapActions
---@field close fun()
---@field reload fun()
---@field toggle_explorer fun()
---@field toggle_commits fun()
---@field toggle_review_panel fun()
---@field toggle_file_reviewed fun()
---@field toggle_resolved fun()
---@field delete_annotation fun()
---@field toggle_comments fun()
---@field toggle_threads fun(all?: boolean): boolean
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

---@param buf integer
---@param groups AtlasDiffKeymapGroup[]
local function register(buf, groups)
	for _, group in ipairs(groups) do
		help.register(group.name, group.items, { buffer = buf, index = group.index })
	end
end

---@param name string
---@param items AtlasHelpKeyItem[]
---@param review_items AtlasHelpKeyItem[]
---@return AtlasDiffKeymapGroup[]
local function groups(name, items, review_items)
	return {
		{ name = name, items = items, index = 1 },
		{ name = "Review", items = review_items, index = 2 },
	}
end

---@param session AtlasDiffSession
---@param actions AtlasDiffKeymapActions
function M.setup(session, actions)
	local result = session.data

	local shared_items = {}
	add(shared_items, "pulls.review.explorer.prev_unreviewed_file", "Previous unreviewed file", 20, function()
		actions.navigate_file(-1, true)
	end)
	add(shared_items, "pulls.review.explorer.next_unreviewed_file", "Next unreviewed file", 21, function()
		actions.navigate_file(1, true)
	end)
	add(shared_items, "pulls.review.explorer.find_file", "Find changed file", 30, actions.find_file)
	add(shared_items, "pulls.review.explorer.toggle_commits", "Toggle commits", 42, actions.toggle_commits)
	add(shared_items, "pulls.review.view.toggle_review_panel", "Toggle review panel", 43, actions.toggle_review_panel)
	add(shared_items, "pulls.review.view.toggle_detail_panel", "Toggle PR details", 44, function()
		actions.dispatch("toggle_detail_panel")
	end)
	add(shared_items, "pulls.review.view.toggle_comments", "Toggle comment display", 45, actions.toggle_comments)

	local review_items = {}
	if result.pr then
		add(review_items, "ui.open_actions", "Review actions", 1, function()
			actions.dispatch("open_actions")
		end)
		add(review_items, "pulls.review.toggle_file_reviewed", "Toggle file reviewed", 2, actions.toggle_file_reviewed)
		add(review_items, "pulls.review.approve", "Approve", 60, function()
			actions.dispatch("approve")
		end)
		add(review_items, "pulls.review.request_changes", "Request changes", 61, function()
			actions.dispatch("request_changes")
		end)
		add(review_items, "pulls.review.submit_review", "Submit review", 62, function()
			actions.dispatch("submit_review")
		end)
		add(review_items, "pulls.review.prev_comment", "Previous comment", 90, function()
			actions.navigate_annotation(-1, "comment")
		end)
		add(review_items, "pulls.review.next_comment", "Next comment", 91, function()
			actions.navigate_annotation(1, "comment")
		end)
		vim.list_extend(review_items, resolver.custom_items("pulls", actions.run_custom))
	end
	if result.notes then
		add(review_items, "pulls.review.prev_note", "Previous note", 92, function()
			actions.navigate_annotation(-1, "note")
		end)
		add(review_items, "pulls.review.next_note", "Next note", 93, function()
			actions.navigate_annotation(1, "note")
		end)
	end
	if result.pr or result.notes then
		add(review_items, "ui.refresh", "Refresh review", 80, function()
			actions.dispatch("refresh_review")
		end)
	end

	local commits_items = vim.list_extend({}, shared_items)
	add(commits_items, "ui.help", "Toggle help", 100, help.toggle)

	if result.pr then
		add(shared_items, "ui.open_in_browser", "Open in browser", 90, function()
			actions.dispatch("open_in_browser")
		end)
	end
	add(shared_items, "ui.help", "Toggle Atlas help", 100, help.toggle)

	-- File comments use the explorer selection; diff comments use the selected lines.
	local explorer_review_items = vim.list_extend({}, review_items)
	if result.pr then
		add(explorer_review_items, "pulls.review.add_comment", "Add pending file comment", 30, function()
			actions.add_comment(true)
		end)
		add(explorer_review_items, "pulls.review.submit_comment", "Post file comment", 31, function()
			actions.add_comment(false)
		end)
	end

	local diff_review_items = vim.list_extend({}, review_items)
	add(diff_review_items, "pulls.review.show_details", "Show comments/notes", 35, session.view.callbacks.show_details)
	if result.pr then
		add(diff_review_items, "pulls.review.add_comment", "Add pending line/selection comment", 30, function()
			actions.add_comment(true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_comment", "Post line/selection comment", 31, function()
			actions.add_comment(false)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.add_suggestion", "Add pending suggestion", 32, function()
			actions.add_comment(true, true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_suggestion", "Post suggestion", 33, function()
			actions.add_comment(false, true)
		end, { "n", "x" })
	end
	if result.notes then
		add(diff_review_items, "pulls.review.add_note", "Add note", 34, actions.add_note, { "n", "x" })
	end
	if result.pr or result.notes then
		add(diff_review_items, "pulls.review.toggle_resolved", "Toggle resolved", 40, actions.toggle_resolved)
		add(diff_review_items, "ui.delete", "Delete comment / note", 41, actions.delete_annotation)
	end

	add(commits_items, "pulls.open_diff", "Open commit diff", 1, actions.open_commit)
	add(commits_items, "pulls.review.show_details", "Show commit details", 2, function()
		commits.show_details(session.commits)
	end)
	add(commits_items, "ui.copy_id", "Copy commit hash", 3, function()
		commits.copy_hash(session.commits)
	end)
	add(commits_items, "ui.open_in_browser", "Open commit in browser", 4, function()
		commits.open_in_browser(session.commits)
	end)
	add(commits_items, "ui.close", "Close commits", 101, function()
		if not help.is_open() then
			actions.toggle_commits()
		end
	end)

	session.renderer.setup_keymaps(session, actions, groups("View", shared_items, diff_review_items))
	register(session.explorer.buf, groups("Explorer", shared_items, explorer_review_items))
	register(session.commits.buf, groups("Commits", commits_items, review_items))
end

return M
