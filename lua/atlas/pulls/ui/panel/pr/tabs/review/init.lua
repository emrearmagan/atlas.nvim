---@class PullsCommentsTab : PullsPanelTabModule
local M = {}

local request_scope = require("atlas.core.requests")
local md_editor = require("atlas.ui.popups.editor")
local statusline = require("atlas.ui.statusline")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.review.renderer")
local review_threads = require("atlas.ui.components.review_threads")
local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.review.keymaps")
local review = require("atlas.pulls.actions.review")

local THREAD_ACTIONS = {
	add_comment = function(context, comment, on_done)
		return review.add_comment(context, { parent = comment }, on_done)
	end,
	edit = review.edit_comment,
	delete = review.delete_comment,
	toggle_task = review.toggle_task,
	toggle_resolved = review.toggle_resolved,
}

---@return AtlasMarkdownCompletionProvider|nil
local function author_completion()
	local provider = require("atlas.pulls.state").provider
	local comments_capability = provider and provider.capabilities.comments
	local data = state.data
	local pr = require("atlas.pulls.ui.panel.pr.state").current_pr
	if not provider or not pr or not data or not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local reviewers = require("atlas.pulls.ui.panel.pr.tabs.overview.state").reviewers
	local conversation = require("atlas.pulls.ui.panel.pr.tabs.conversation.state").comments
	return comments_capability.comment_completion({
		pr = pr,
		comments = data.comments,
		tasks = data.tasks,
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = type(conversation) == "table" and conversation or nil,
	})
end

local requests = request_scope.new()
local tab_active = false
local generation = 0

---@return integer
local function invalidate()
	generation = generation + 1
	return generation
end

---@param expected_generation integer
---@param pr PullRequest
---@return boolean
local function is_current(expected_generation, pr)
	return tab_active and generation == expected_generation and panel_state.current_pr == pr
end

function M.reset()
	invalidate()
	requests.cancel()
	requests = request_scope.new()
	state.reset()
end

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param opts { key: string, title: string, initial_text: string|nil, preview: AtlasMarkdownEditorPreview|nil, on_save: fun(text: string|nil) }
local function open_md_editor(opts)
	md_editor.open({
		key = opts.key,
		title = opts.title,
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = opts.initial_text,
		completion = author_completion(),
		preview = opts.preview,
		on_save = opts.on_save,
	})
end

-- Lifecycle

---@param pr PullRequest
---@param _repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, _repo, refresh, opts)
	M.reset()
	local request_generation = generation

	local provider = get_provider()
	local reviews = provider and provider.capabilities.reviews
	if reviews == nil then
		state.status = "Pull request provider is not available"
		refresh()
		return
	end

	local pr_id = tostring(pr.id or "")
	state.status = "loading"
	statusline.notify("loading", string.format("Loading review for #%s...", pr_id))

	requests.run(function(done)
		return reviews.fetch(pr, opts, done)
	end, function(data, err)
		if not is_current(request_generation, pr) then
			return
		end
		if err or not data then
			local message = tostring(err or "Provider returned no review data")
			state.status = message
			statusline.notify("error", string.format("Failed to load review for #%s: %s", pr_id, message))
		else
			state.data = data
			state.status = nil
			statusline.notify("success", string.format("Review loaded for #%s", pr_id), 1200)
		end
		refresh()
	end)
end

---@param _pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, width)
	local completion = author_completion()
	if completion and completion.resolve_items then
		completion.resolve_items()
	end
	if state.status then
		return renderer.render(width, state.status, nil)
	end
	local data = state.data
	local provider = get_provider()
	return renderer.render(
		width,
		data and data.comments or nil,
		data and data.tasks or nil,
		provider and provider.capabilities.tasks
	)
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	local k = entry.kind
	return k == "header"
		or k == "content"
		or k == "thread_header"
		or k == "thread_content"
		or k == "hunk_header"
		or k == "hunk_line"
		or k == "file_header"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	if entry.kind == "hunk_header" and entry.hunk_key then
		state.collapsed_hunks[entry.hunk_key] = state.collapsed_hunks[entry.hunk_key] ~= true
		return true
	end

	local comment = entry.comment
	if comment ~= nil and (entry.entity_kind == "comment" or entry.entity_kind == "task") then
		local url = tostring(comment.html_url or comment.url or "")
		if url ~= "" then
			vim.ui.open(url)
			return true
		end
	end
end

---@param _pr PullRequest
---@param entry table|nil
---@param buf integer
function M.show_details(_pr, entry, buf)
	local task = entry and entry.entity_kind == "task" and entry.comment or nil
	if task == nil then
		return
	end

	local utils = require("atlas.ui.shared.utils")
	local content = utils.task_text(task.content_display or task.content_raw)
	local empty = string.format("(empty %s)", (task.task_label or "task"):lower())
	local lines = vim.split(content ~= "" and content or empty, "\n", { plain = true })
	lines[1] = (task.state == "RESOLVED" and "[x] " or "[ ] ") .. lines[1]

	local author = task.author
	local author_name = "Unknown"
	if author then
		if author.nickname and author.nickname ~= "" then
			author_name = author.nickname
		elseif author.name and author.name ~= "" then
			author_name = author.name
		end
	end
	table.insert(lines, "")
	table.insert(lines, string.format("by @%s  %s", author_name, utils.relative_time(task.created_on)))
	require("atlas.ui.popups.info").show({ lines = lines, source_buf = buf })
end

---@return boolean
function M.is_loading()
	return state.any_loading()
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	tab_active = true
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	tab_active = false
	invalidate()
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	requests.cancel()
	requests = request_scope.new()
end

---@param pr PullRequest
---@param key "comments"|"tasks"
---@return AtlasReviewActionContext|nil
local function action_context(pr, key)
	local provider = get_provider()
	local data = state.data
	if not provider or not data then
		return nil
	end
	local items = data[key]
	return {
		provider = provider,
		pr = pr,
		items = items,
		data = data,
		completion = author_completion(),
	}
end

-- Actions

---@param action AtlasReviewThreadAction
---@param pr PullRequest
---@param entry table
---@param refresh fun()
local function run_comment_action(action, pr, entry, refresh)
	local comment = entry and entry.comment
	local context = comment and action_context(pr, comment.is_task and "tasks" or "comments") or nil
	if comment and context then
		local on_done = function(result, err)
			if result and not err then
				if result.changed_pr then
					require("atlas.pulls.ui.main.controller").refresh_pr(pr)
				else
					refresh()
				end
			end
		end
		local handler = THREAD_ACTIONS[action]
		if handler then
			handler(context, comment, on_done)
		end
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply_comment(pr, entry, refresh)
	run_comment_action("add_comment", pr, entry, refresh)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit_comment(pr, entry, refresh)
	run_comment_action("edit", pr, entry, refresh)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete_comment(pr, entry, refresh)
	run_comment_action("delete", pr, entry, refresh)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.toggle_resolved(pr, entry, refresh)
	local comment = entry and entry.comment
	local action = comment and comment.is_task and "toggle_task" or "toggle_resolved"
	local target = action == "toggle_resolved" and entry and entry.thread_root or comment
	run_comment_action(action, pr, { comment = target }, refresh)
end

---@param pr PullRequest
---@param refresh fun()
function M.add_task(pr, refresh)
	local provider = get_provider()
	local tasks_capability = provider and provider.capabilities.tasks
	if not tasks_capability or not tasks_capability.add_task then
		statusline.notify("error", "Provider does not support tasks")
		return
	end
	local add_task = tasks_capability.add_task
	local data = state.data
	if not data then
		return
	end
	local tasks = data.tasks

	local win = require("atlas.ui.layout").win_id("detail")
	local parent = nil
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local ent = (panel_state.line_map or {})[lnum]
		if ent and ent.comment and not ent.comment.is_task then
			parent = ent.comment
		end
	end
	local preview
	if parent then
		preview = review_threads.render_comment(parent, math.max(math.floor(vim.o.columns * 0.5), 80))
	end

	open_md_editor({
		key = "pr-task-add-" .. tostring(pr.id or ""),
		title = " Add Task ",
		preview = preview,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				statusline.notify("warn", "Task cannot be empty")
				return
			end
			statusline.notify("loading", "Adding task...")
			add_task(pr, text, parent, function(task, err)
				if err then
					statusline.notify("error", tostring(err))
					return
				end
				if task then
					table.insert(tasks, task)
				end
				statusline.notify("success", "Task added", 1200)
				refresh()
			end)
		end,
	})
end

return M
