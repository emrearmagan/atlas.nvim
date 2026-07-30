---@class PullsCommentsTab : PullsPanelTabModule
local M = {}

local md_editor = require("atlas.ui.popups.editor")
local footer = require("atlas.ui.components.footer")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.review.renderer")
local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.review.keymaps")
local review_actions = require("atlas.pulls.actions.review")

---@return AtlasMarkdownCompletionProvider|nil
local function author_completion()
	local provider = require("atlas.pulls.state").provider
	local comments = state.comments
	local tasks = state.tasks
	local pr = require("atlas.pulls.ui.panel.pr.state").current_pr
	if
		not provider
		or not pr
		or not provider.comment_completion
		or (type(comments) ~= "table" and type(tasks) ~= "table")
	then
		return nil
	end
	local reviewers = require("atlas.pulls.ui.panel.pr.tabs.overview.state").reviewers
	local conversation = require("atlas.pulls.ui.panel.pr.tabs.conversation.state").comments
	return provider.comment_completion({
		pr = pr,
		comments = type(comments) == "table" and comments or {},
		tasks = type(tasks) == "table" and tasks or nil,
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = type(conversation) == "table" and conversation or nil,
	})
end

---@type { cancel: fun() }[]
local in_flight = {}
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

---@param expected_generation integer
---@param pr PullRequest
---@param key "comments"|"tasks"
---@param items PullsComment[]
---@return boolean
local function is_current_list(expected_generation, pr, key, items)
	return is_current(expected_generation, pr) and state[key] == items
end

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		pcall(handle.cancel)
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param opts { key: string, title: string, initial_text: string|nil, on_save: fun(text: string|nil) }
local function open_md_editor(opts)
	md_editor.open({
		key = opts.key,
		title = opts.title,
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = opts.initial_text,
		completion = author_completion(),
		on_save = opts.on_save,
	})
end

-- -----------------------------------------------------------------------------
-- Lifecycle
-- -----------------------------------------------------------------------------

---@param pr PullRequest
---@param _repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, _repo, refresh, opts)
	local request_generation = invalidate()
	cancel_all()
	state.reset()

	local provider = get_provider()
	if provider == nil then
		state.comments = "Pull request provider is not available"
		refresh()
		return
	end

	local pr_id = tostring(pr.id or "")
	state.comments = "loading"
	state.tasks = provider.fetch_tasks and "loading" or nil
	footer.notify("loading", string.format("Loading review for #%s...", pr_id))

	local pending = provider.fetch_tasks and 2 or 1
	local comments_error, tasks_error
	local function complete()
		pending = pending - 1
		refresh()
		if pending > 0 then
			return
		end
		if comments_error then
			footer.notify("error", string.format("Failed to load comments for #%s: %s", pr_id, comments_error))
		elseif tasks_error then
			footer.notify("warn", string.format("Failed to load review items for #%s: %s", pr_id, tasks_error))
		else
			footer.notify("success", string.format("Review loaded for #%s", pr_id), 1200)
		end
	end

	local comments_handle = provider.fetch_comments(pr, opts, function(comments, err)
		if not is_current(request_generation, pr) then
			return
		end
		if err then
			comments_error = tostring(err)
			state.comments = comments_error
		else
			state.comments = comments or {}
		end
		complete()
	end)
	track(comments_handle)

	local fetch_tasks = provider.fetch_tasks
	if fetch_tasks then
		local tasks_handle = fetch_tasks(pr, opts, function(tasks, err)
			if not is_current(request_generation, pr) then
				return
			end
			if err then
				tasks_error = tostring(err)
				state.tasks = tasks_error
			else
				state.tasks = tasks or {}
			end
			complete()
		end)
		track(tasks_handle)
	end
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	local completion = author_completion()
	if completion and completion.resolve_items then
		completion.resolve_items()
	end
	return renderer.render(pr, width, state.comments, state.tasks)
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
	cancel_all()
end

---@param pr PullRequest
---@param refresh fun()
---@param key "comments"|"tasks"
---@return AtlasReviewCommentActionContext|nil
local function action_context(pr, refresh, key)
	local provider = get_provider()
	local items = state[key]
	if not provider or type(items) ~= "table" then
		return nil
	end
	---@cast items PullsComment[]
	local context_generation = generation
	return {
		provider = provider,
		pr = pr,
		current_user = require("atlas.pulls.state").current_user,
		items = items,
		completion = author_completion(),
		active = function()
			return is_current_list(context_generation, pr, key, items)
		end,
		track = track,
		refresh = refresh,
	}
end

-- -----------------------------------------------------------------------------
-- Actions
-- -----------------------------------------------------------------------------

---@param action AtlasReviewCommentAction
---@param pr PullRequest
---@param entry table
---@param refresh fun()
local function run_comment_action(action, pr, entry, refresh)
	local comment = entry and entry.comment
	local context = comment and action_context(pr, refresh, comment.is_task and "tasks" or "comments") or nil
	if comment and context then
		review_actions.run(context, action, comment)
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply_comment(pr, entry, refresh)
	run_comment_action("reply", pr, entry, refresh)
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
	if not provider or not provider.add_task then
		footer.notify("error", "Provider does not support tasks")
		return
	end
	local add_task = provider.add_task
	local tasks = state.tasks
	if type(tasks) ~= "table" then
		return
	end
	---@cast tasks PullsComment[]
	local context_generation = generation
	if not is_current_list(context_generation, pr, "tasks", tasks) then
		return
	end

	local win = require("atlas.ui.layout").win_id("detail")
	local parent = nil
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local ent = (panel_state.line_map or {})[lnum]
		if ent and ent.comment and not ent.comment.is_task then
			parent = ent.comment
		end
	end

	open_md_editor({
		key = "pr-task-add-" .. tostring(pr.id or ""),
		title = " Add Task ",
		on_save = function(text)
			if not is_current_list(context_generation, pr, "tasks", tasks) then
				return
			end
			if not text or vim.trim(text) == "" then
				footer.notify("warn", "Task cannot be empty")
				return
			end
			footer.notify("loading", "Adding task...")
			track(add_task(pr, text, parent, function(task, err)
				if not is_current_list(context_generation, pr, "tasks", tasks) then
					return
				end
				if err then
					footer.notify("error", tostring(err))
					return
				end
				if task then
					table.insert(tasks, task)
				end
				footer.notify("success", "Task added", 1200)
				refresh()
			end))
		end,
	})
end

return M
