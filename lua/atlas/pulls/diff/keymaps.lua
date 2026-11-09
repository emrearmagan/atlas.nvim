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
	explorer = vim.list_extend({ "ui.copy_url" }, shared_actions),
}

---@class AtlasDiffKeymapGroup
---@field name string
---@field items AtlasHelpKeyItem[]
---@field index integer

---@param items AtlasHelpKeyItem[]
---@param actions AtlasKeymapActionId|AtlasKeymapActionId[]
---@param index integer
---@param callback fun()
---@param mode string|string[]|nil
local function add(items, actions, index, callback, mode)
	local keymap = resolver.resolve(actions)
	if keymap then
		items[#items + 1] = {
			key = keymap.key,
			desc = keymap.desc,
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
	add(shared_items, "pulls.review.explorer.prev_unreviewed_file", 20, function()
		viewer:navigate_file(-1, true)
	end)
	add(shared_items, "pulls.review.explorer.next_unreviewed_file", 21, function()
		viewer:navigate_file(1, true)
	end)
	add(shared_items, "pulls.review.explorer.find_file", 30, function()
		viewer:find_file()
	end)
	add(shared_items, "pulls.review.explorer.toggle_commits", 42, function()
		viewer:toggle_commits()
	end)
	if session.source.kind == "pr" then
		add(shared_items, "pulls.review.view.toggle_review_panel", 43, function()
			viewer:toggle_review_panel()
		end)
	end
	add(shared_items, "pulls.review.view.toggle_detail_panel", 44, function()
		viewer:run_action("toggle_detail_panel")
	end)
	add(shared_items, "pulls.review.view.toggle_comments", 45, function()
		viewer:toggle_comments()
	end)
	add(shared_items, "pulls.review.prev_commit", 46, function()
		viewer:step_commit(-1)
	end)
	add(shared_items, "pulls.review.next_commit", 47, function()
		viewer:step_commit(1)
	end)

	local review_items = {}
	if session.source.kind == "pr" then
		add(review_items, "ui.open_actions", 1, function()
			viewer:run_action("open_actions")
		end)
		add(review_items, "pulls.review.toggle_file_reviewed", 2, function()
			viewer:toggle_file_reviewed()
		end)
		add(review_items, "pulls.review.approve", 60, function()
			viewer:run_action("approve")
		end)
		add(review_items, "pulls.review.request_changes", 61, function()
			viewer:run_action("request_changes")
		end)
		add(review_items, "pulls.review.submit_review", 62, function()
			viewer:run_action("submit_review")
		end)
		add(review_items, "pulls.review.prev_comment", 90, function()
			viewer:navigate_annotation(-1, "comment")
		end)
		add(review_items, "pulls.review.next_comment", 91, function()
			viewer:navigate_annotation(1, "comment")
		end)
		add(review_items, "pulls.review.prev_unresolved", 94, function()
			viewer:navigate_annotation(-1, "unresolved")
		end)
		add(review_items, "pulls.review.next_unresolved", 95, function()
			viewer:navigate_annotation(1, "unresolved")
		end)
	end
	if session.notes then
		add(review_items, "pulls.review.prev_note", 92, function()
			viewer:navigate_annotation(-1, "note")
		end)
		add(review_items, "pulls.review.next_note", 93, function()
			viewer:navigate_annotation(1, "note")
		end)
	end
	if session.source.kind == "pr" then
		add(review_items, "ui.refresh", 80, function()
			viewer:run_action("refresh_review")
		end)
	end

	local commits_items = vim.list_extend({}, shared_items)
	add(commits_items, "ui.help", 100, help.toggle)

	if session.source.kind == "pr" then
		add(shared_items, "ui.open_in_browser", 90, function()
			viewer:open_in_browser()
		end)
	end
	add(shared_items, "ui.help", 100, help.toggle)

	local explorer_items = vim.list_extend({}, shared_items)
	if session.source.kind == "pr" then
		add(explorer_items, "ui.copy_url", 91, function()
			viewer:run_action("copy_url")
		end)
	end

	-- File comments use the explorer selection; diff comments use the selected lines.
	local explorer_review_items = vim.list_extend({}, review_items)
	if session.source.kind == "pr" then
		add(explorer_review_items, "pulls.review.add_comment", 30, function()
			viewer:add_comment(true)
		end)
		add(explorer_review_items, "pulls.review.submit_comment", 31, function()
			viewer:add_comment(false)
		end)
	end

	local diff_review_items = vim.list_extend({}, review_items)
	add(diff_review_items, "pulls.review.show_details", 35, function()
		viewer:show_details()
	end)
	if session.source.kind == "pr" then
		add(diff_review_items, "pulls.review.add_comment", 30, function()
			viewer:add_comment(true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_comment", 31, function()
			viewer:add_comment(false)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.add_suggestion", 32, function()
			viewer:add_comment(true, true)
		end, { "n", "x" })
		add(diff_review_items, "pulls.review.submit_suggestion", 33, function()
			viewer:add_comment(false, true)
		end, { "n", "x" })
	end
	if session.notes then
		add(diff_review_items, "pulls.review.add_note", 34, function()
			viewer:add_note()
		end, { "n", "x" })
	end
	if session.source.kind == "pr" then
		add(diff_review_items, "pulls.review.toggle_resolved", 40, function()
			viewer:run_annotation_action("toggle_resolved")
		end)
		add(diff_review_items, "ui.delete", 41, function()
			viewer:run_annotation_action("delete_comment")
		end)
	end

	add(commits_items, { "ui.select", "pulls.open_diff" }, 1, function()
		viewer:show_commits(viewer.commits:selection())
	end, { "n", "x" })
	add(commits_items, "pulls.review.show_details", 2, function()
		viewer.commits:show_details()
	end)
	add(commits_items, "ui.copy_id", 3, function()
		viewer.commits:copy_hash()
	end)
	add(commits_items, "ui.close", 101, function()
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
	register(viewer.explorer.buf, groups("Explorer", explorer_items, explorer_review_items, custom_items))
	register(viewer.commits.buf, groups("Commits", commits_items, review_items, custom_items))
end

---@param viewer AtlasDiffViewer
---@param buf integer
---@return AtlasKeymapActionId[]
function M.hints(viewer, buf)
	if vim.bo[buf].filetype == "atlas-ui.review-thread" then
		return {
			"ui.comments.reply",
			"pulls.review.toggle_resolved",
			"ui.close",
		}
	elseif buf == viewer.commits.buf then
		return {
			"pulls.open_diff",
			"pulls.review.show_details",
		}
	end

	return {
		"pulls.review.show_details",
		"pulls.review.add_comment",
		"pulls.review.submit_comment",
		"pulls.review.toggle_file_reviewed",
		"pulls.review.submit_review",
	}
end

return M
