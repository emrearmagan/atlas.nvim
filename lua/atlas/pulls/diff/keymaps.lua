local resolver = require("atlas.core.keymaps")
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
	"pulls.review.next_unresolved",
	"pulls.review.prev_unresolved",
	"pulls.review.next_note",
	"pulls.review.prev_note",
	"pulls.review.next_commit",
	"pulls.review.prev_commit",
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

---@param items AtlasHelpKeyItem[]
---@param actions AtlasKeymapActionId|AtlasKeymapActionId[]
---@param desc string
---@param index integer
---@param callback fun()
---@param mode string|string[]|nil
local function add(items, actions, desc, index, callback, mode)
	if type(actions) == "string" then
		actions = { actions }
	end
	local keys = {}
	for _, action in ipairs(actions) do
		vim.list_extend(keys, resolver.resolve(action) or {})
	end
	if #keys > 0 then
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
---@param custom_items AtlasHelpKeyItem[]
---@return AtlasDiffKeymapGroup[]
local function groups(name, items, review_items, custom_items)
	return {
		{ name = name, items = items, index = 1 },
		{ name = "Review", items = review_items, index = 2 },
		{ name = "Custom", items = custom_items, index = 3 },
	}
end

---@param viewer AtlasDiffViewer
function M.setup(viewer)
	local session = viewer.session

	local shared_items = {}
	add(shared_items, "pulls.review.explorer.prev_unreviewed_file", "Previous unreviewed file", 20, function()
		viewer:navigate_file(-1, true)
	end)
	add(shared_items, "pulls.review.explorer.next_unreviewed_file", "Next unreviewed file", 21, function()
		viewer:navigate_file(1, true)
	end)
	add(shared_items, "pulls.review.explorer.find_file", "Find changed file", 30, function()
		viewer:find_file()
	end)
	add(shared_items, "pulls.review.explorer.toggle_commits", "Toggle commits", 42, function()
		viewer:toggle_commits()
	end)
	if session.source.kind == "pr" then
		add(shared_items, "pulls.review.view.toggle_review_panel", "Toggle review panel", 43, function()
			viewer:toggle_review_panel()
		end)
	end
	add(shared_items, "pulls.review.view.toggle_detail_panel", "Toggle PR details", 44, function()
		viewer:run_action("toggle_detail_panel")
	end)
	add(shared_items, "pulls.review.view.toggle_comments", "Toggle comment display", 45, function()
		viewer:toggle_comments()
	end)
	add(shared_items, "pulls.review.prev_commit", "Previous commit", 46, function()
		viewer:step_commit(-1)
	end)
	add(shared_items, "pulls.review.next_commit", "Next commit", 47, function()
		viewer:step_commit(1)
	end)

	local review_items = {}
	if session.source.kind == "pr" then
		add(review_items, "ui.open_actions", "Review actions", 1, function()
			viewer:run_action("open_actions")
		end)
		add(review_items, "pulls.review.toggle_file_reviewed", "Toggle reviewed", 2, function()
			viewer:toggle_file_reviewed()
		end)
		add(review_items, "pulls.review.approve", "Approve", 60, function()
			viewer:run_action("approve")
		end)
		add(review_items, "pulls.review.request_changes", "Request changes", 61, function()
			viewer:run_action("request_changes")
		end)
		add(review_items, "pulls.review.submit_review", "Submit review", 62, function()
			viewer:run_action("submit_review")
		end)
		add(review_items, "pulls.review.prev_comment", "Previous comment", 90, function()
			viewer:navigate_annotation(-1, "comment")
		end)
		add(review_items, "pulls.review.next_comment", "Next comment", 91, function()
			viewer:navigate_annotation(1, "comment")
		end)
		add(review_items, "pulls.review.prev_unresolved", "Previous unresolved thread", 94, function()
			viewer:navigate_annotation(-1, "unresolved")
		end)
		add(review_items, "pulls.review.next_unresolved", "Next unresolved thread", 95, function()
			viewer:navigate_annotation(1, "unresolved")
		end)
	end
	if session.notes then
		add(review_items, "pulls.review.prev_note", "Previous note", 92, function()
			viewer:navigate_annotation(-1, "note")
		end)
		add(review_items, "pulls.review.next_note", "Next note", 93, function()
			viewer:navigate_annotation(1, "note")
		end)
	end
	if session.source.kind == "pr" then
		add(review_items, "ui.refresh", "Refresh review", 80, function()
			viewer:run_action("refresh_review")
		end)
	end

	local commits_items = vim.list_extend({}, shared_items)
	add(commits_items, "ui.help", "Toggle help", 100, help.toggle)

	if session.source.kind == "pr" then
		add(shared_items, "ui.open_in_browser", "Open in browser", 90, function()
			viewer:open_in_browser()
		end)
	end
	add(shared_items, "ui.help", "Toggle Atlas help", 100, help.toggle)

	-- File comments use the explorer selection; diff comments use the selected lines.
	local explorer_review_items = vim.list_extend({}, review_items)
	if session.source.kind == "pr" then
		add(explorer_review_items, "pulls.review.add_comment", "Add pending file comment", 30, function()
			viewer:add_comment(true)
		end)
		add(explorer_review_items, "pulls.review.submit_comment", "Post file comment", 31, function()
			viewer:add_comment(false)
		end)
	end

	local diff_review_items = vim.list_extend({}, review_items)
	add(diff_review_items, "pulls.review.show_details", "Show comments/notes", 35, function()
		viewer:show_details()
	end)
	if session.source.kind == "pr" then
		add(diff_review_items, "pulls.review.add_comment", "Add pending line/selection comment", 30, function()
			viewer:add_comment(true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_comment", "Post line/selection comment", 31, function()
			viewer:add_comment(false)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.add_suggestion", "Add pending suggestion", 32, function()
			viewer:add_comment(true, true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_suggestion", "Post suggestion", 33, function()
			viewer:add_comment(false, true)
		end, { "n", "x" })
	end
	if session.notes then
		add(diff_review_items, "pulls.review.add_note", "Add note", 34, function()
			viewer:add_note()
		end, { "n", "x" })
	end
	if session.source.kind == "pr" then
		add(diff_review_items, "pulls.review.toggle_resolved", "Toggle resolved", 40, function()
			viewer:run_annotation_action("toggle_resolved")
		end)
		add(diff_review_items, "ui.delete", "Delete comment / note", 41, function()
			viewer:run_annotation_action("delete_comment")
		end)
	end

	add(commits_items, { "ui.select", "pulls.open_diff" }, "Show commits", 1, function()
		viewer:show_commits(viewer.commits:selection())
	end, { "n", "x" })
	add(commits_items, "pulls.review.show_details", "Show commit details", 2, function()
		viewer.commits:show_details()
	end)
	add(commits_items, "ui.copy_id", "Copy commit hash", 3, function()
		viewer.commits:copy_hash()
	end)
	add(commits_items, "ui.close", "Close commits", 101, function()
		if not help.is_open() then
			viewer:toggle_commits()
		end
	end)

	local custom_items = session.source.kind == "pr"
			and resolver.custom_items("pulls", function(callback)
				return viewer:run_custom(callback)
			end)
		or {}
	viewer.renderer:setup_keymaps(viewer, groups("View", shared_items, diff_review_items, custom_items))
	register(viewer.explorer.buf, groups("Explorer", shared_items, explorer_review_items, custom_items))
	register(viewer.commits.buf, groups("Commits", commits_items, review_items, custom_items))
end

return M
