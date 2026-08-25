local M = {}

local diff_parser = require("atlas.core.git.diff_parser")
local request_scope = require("atlas.core.requests")
local md_editor = require("atlas.ui.popups.editor")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.detail.state")
local renderer = require("atlas.pulls.ui.detail.tabs.review.renderer")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local state = require("atlas.pulls.ui.detail.tabs.review.state")
local keymaps = require("atlas.pulls.ui.detail.tabs.review.keymaps")
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
	local provider = detail.provider
	local comments_capability = provider and provider.capabilities.comments
	local data = state.data
	local pr = detail.current_pr
	if not provider or not pr or not data or not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local reviewers = require("atlas.pulls.ui.detail.tabs.overview.state").reviewers
	local conversation = require("atlas.pulls.ui.detail.tabs.conversation.state").comments(false)
	return comments_capability.comment_completion({
		pr = pr,
		details = detail.current_details,
		comments = data.comments,
		tasks = data.tasks,
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = conversation,
	})
end

---@param pr PullRequest
---@return boolean
local function is_current(pr)
	return state.current_pr ~= nil
		and tostring(state.current_pr.id or "") == tostring(pr.id or "")
		and tostring(state.current_pr.repo_full_name or "") == tostring(pr.repo_full_name or "")
end

function M.reset()
	state.reset()
	notify.clear()
end

---@param comments PullsComment[]
---@param files DiffFile[]
local function set_hunks(comments, files)
	local by_path = {}
	for _, file in ipairs(files) do
		by_path[file.path] = file
		if file.old_path and by_path[file.old_path] == nil then
			by_path[file.old_path] = file
		end
	end

	local hunks = {}
	for _, comment in ipairs(comments) do
		local inline = comment.inline
		local anchor = inline and (inline.to or inline.from)
		if inline and anchor and comment.outdated ~= true then
			local side = inline.to ~= nil and "new" or "old"
			local hunk = diff_parser.find_hunk(by_path[inline.path], side, anchor)
			if hunk then
				hunks[tostring(comment.id)] = { hunk = hunk, anchor = anchor }
			end
		end
	end
	state.hunks_by_comment = hunks
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
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	M.reset()
	state.current_pr = pr

	local provider = detail.provider
	local reviews = provider and provider.capabilities.reviews
	if reviews == nil then
		state.status = "Pull request provider is not available"
		refresh()
		return
	end

	local pr_id = tostring(pr.id or "")
	state.status = "loading"
	notify.loading(string.format("Loading review for #%s...", pr_id))

	state.requests.run(function(done)
		return reviews.fetch(pr, opts, done)
	end, function(data, err)
		if not is_current(pr) then
			return
		end
		if err or not data then
			local message = tostring(err or "Provider returned no review data")
			state.status = message
			notify.error(string.format("Failed to load review for #%s: %s", pr_id, message))
			refresh()
			return
		end

		local fetch_diff = provider.capabilities.core.fetch_diff
		local needs_diff = false
		for _, comment in ipairs(data.comments) do
			local inline = comment.inline
			if comment.outdated ~= true and inline and inline.path and (inline.to or inline.from) then
				needs_diff = true
				break
			end
		end
		if not needs_diff or not fetch_diff then
			state.data = data
			state.status = nil
			notify.success(string.format("Review loaded for #%s", pr_id), { timeout = 1200 })
			refresh()
			return
		end

		notify.loading(string.format("Loading diff context for #%s...", pr_id))
		state.requests.run(function(done)
			return fetch_diff(pr, opts, done)
		end, function(files, diff_err)
			if not is_current(pr) then
				return
			end
			if files then
				set_hunks(data.comments, files)
				notify.success(string.format("Review loaded for #%s", pr_id), { timeout = 1200 })
			else
				local message = tostring(diff_err or "Provider returned no diff data")
				notify.warn("Review loaded without diff context: " .. message)
			end
			state.data = data
			state.status = nil
			refresh()
		end)
	end)
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, _details, width)
	local completion = author_completion()
	if completion and completion.resolve_items then
		completion.resolve_items()
	end
	if state.status then
		return renderer.render(width, state.status, nil)
	end
	local data = state.data
	return renderer.render(width, data and data.comments or nil, data and data.tasks or nil, state.hunks_by_comment)
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
		or k == "hunk_line"
		or k == "file_header"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	local comment = entry.comment
	if comment ~= nil and (entry.entity_kind == "comment" or entry.entity_kind == "task") then
		local url = tostring(comment.html_url or comment.url or "")
		if url ~= "" then
			vim.ui.open(url)
			return true
		end
	end
end

---@param entry table|nil
---@param buf integer
function M.show_details(entry, buf)
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
	return state.status == "loading"
end

function M.activate(buf, refresh)
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	state.current_pr = nil
	keymaps.teardown(buf)
	state.requests.cancel()
	state.requests = request_scope.new()
	notify.clear()
end

---@param pr PullRequest
---@param key "comments"|"tasks"
---@return AtlasReviewActionContext|nil
local function action_context(pr, key)
	local provider = detail.provider
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
		notify = function(level, message, duration)
			if is_current(pr) then
				notify.show(level, message, { timeout = duration })
			end
		end,
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
		local handler = THREAD_ACTIONS[action]
		if handler then
			local on_update = detail.on_update
			local on_done = function(result, err)
				if result and not err then
					if result.changed_pr then
						if on_update then
							on_update(pr, result)
						else
							require("atlas.pulls.ui.detail").refresh()
						end
					elseif is_current(pr) then
						refresh()
					end
				end
			end
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
	local provider = detail.provider
	local tasks_capability = provider and provider.capabilities.tasks
	if not tasks_capability or not tasks_capability.add_task then
		notify.error("Provider does not support tasks")
		return
	end
	local add_task = tasks_capability.add_task
	local data = state.data
	if not data then
		return
	end
	local tasks = data.tasks

	local win = detail.win
	local parent = nil
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local ent = detail.line_map[lnum]
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
			if not is_current(pr) then
				return
			end
			if not text or vim.trim(text) == "" then
				notify.warn("Task cannot be empty")
				return
			end
			notify.loading("Adding task...")
			add_task(pr, text, parent, function(task, err)
				if not is_current(pr) then
					return
				end
				if err then
					notify.error(tostring(err))
					return
				end
				if task then
					table.insert(tasks, task)
				end
				notify.success("Task added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

return M
