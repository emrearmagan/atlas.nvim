local M = {}

local action_runner = require("atlas.core.actions")
local request_scope = require("atlas.core.requests")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.detail.state")
local renderer = require("atlas.pulls.ui.detail.tabs.review.renderer")
local state = require("atlas.pulls.ui.detail.tabs.review.state")
local keymaps = require("atlas.pulls.ui.detail.tabs.review.keymaps")
local review = require("atlas.pulls.actions.review")
local conversation = require("atlas.pulls.ui.detail.tabs.conversation.state")
local utils = require("atlas.ui.shared.utils")

---@param pr PullRequest
---@return (fun(text: string): string)|nil
local function comment_formatter(pr)
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.comment_formatter then
		return nil
	end
	return comments.comment_formatter({
		pr = pr,
		details = detail.current_details,
		data = state.data,
		conversation = conversation.comments(),
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
		return reviews.fetch_threads(pr, opts, done)
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

		state.data = data
		state.status = nil
		notify.success(string.format("Review loaded for #%s", pr_id), { timeout = 1200 })
		refresh()
	end)
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, _details, width)
	if state.status then
		return renderer.render(width, state.status, nil)
	end
	local data = state.data
	return renderer.render(width, data and data.comments or nil, data and data.tasks or nil, comment_formatter(pr))
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
	local pr = detail.current_pr
	if not task or not pr then
		return
	end

	local content = task.content_raw or ""
	local format_text = comment_formatter(pr)
	if format_text then
		content = format_text(content)
	end
	content = utils.task_text(content)
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
---@return AtlasReviewActionContext|nil
local function action_context(pr)
	local provider = detail.provider
	local data = state.data
	if not provider or not data then
		return nil
	end
	return {
		provider = provider,
		pr = pr,
		data = data,
		details = detail.current_details,
		conversation = conversation.comments(),
		notify = function(level, message, duration)
			if is_current(pr) then
				notify.show(level, message, { timeout = duration })
			end
		end,
	}
end

-- Actions

---@param action "add_comment"|"edit_comment"|"delete_comment"|"toggle_task"|"toggle_resolved"
---@param pr PullRequest
---@param entry table
---@param refresh fun()
local function run_comment_action(action, pr, entry, refresh)
	local comment = entry and entry.comment
	if not comment then
		return
	end
	local context = action_context(pr)
	if not context then
		return
	end
	context.comment = comment
	local on_update = detail.on_update
	action_runner.run(review[action], context, function(result, err)
		if not result or err then
			return
		end
		if result.changed_pr then
			if on_update then
				on_update(pr, result)
			else
				require("atlas.pulls.ui.detail").refresh()
			end
		elseif is_current(pr) then
			refresh()
		end
	end)
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
	run_comment_action("edit_comment", pr, entry, refresh)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete_comment(pr, entry, refresh)
	run_comment_action("delete_comment", pr, entry, refresh)
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
	local context = action_context(pr)
	if not context then
		return
	end

	local win = detail.win
	local parent = nil
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local ent = detail.line_map[lnum]
		if ent and ent.comment and not ent.comment.is_task then
			parent = ent.comment
		end
	end
	context.comment = parent
	action_runner.run(review.add_task, context, function(result, err)
		if result and not err and is_current(pr) then
			refresh()
		end
	end)
end

return M
