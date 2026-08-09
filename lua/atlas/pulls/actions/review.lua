local M = {}

local editor = require("atlas.ui.popups.editor")
local statusline = require("atlas.ui.statusline")
local review_threads = require("atlas.ui.components.review_threads")

---@class AtlasReviewActionContext: AtlasPullActionContext
---@field pr PullRequest
---@field items PullsComment[]|nil
---@field completion AtlasMarkdownCompletionProvider|nil
---@field active (fun(): boolean)|nil
---@field track (fun(handle: { cancel: fun() }|nil): fun())|nil

---@param provider PullsProvider
---@param pr PullRequest
---@param comments PullsComment[]
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(provider, pr, comments)
	local capability = provider.capabilities.comments
	if not capability or not capability.comment_completion then
		return nil
	end
	return capability.comment_completion({ pr = pr, comments = comments })
end

---@param context AtlasReviewActionContext
---@param opts AtlasMarkdownEditorOptions
local function open_editor(context, opts)
	opts.width_ratio = 0.5
	opts.height_ratio = 0.18
	opts.completion = opts.completion or context.completion
	if opts.completion == nil and context.items then
		opts.completion = author_completion(context.provider, context.pr, context.items)
	end
	editor.open(opts)
end

---@param context AtlasReviewActionContext
---@param level "loading"|"success"|"info"|"warn"|"error"
---@param message string
---@param duration? integer
local function notify(context, level, message, duration)
	if context.notify then
		context.notify(level, message, duration)
		return
	end
	statusline.notify(level, message, duration)
end

---@param context AtlasReviewActionContext
---@return boolean
local function active(context)
	return context.active == nil or context.active()
end

---@param context AtlasReviewActionContext
---@param start fun(done: fun(...)): { cancel: fun() }|nil
---@param done fun(...)
local function run_request(context, start, done)
	local finished = false
	local release
	local function complete(...)
		if finished then
			return
		end
		finished = true
		if release then
			release()
		end
		done(...)
	end
	local handle = start(complete)
	release = context.track and context.track(handle) or function() end
	if finished then
		release()
	end
end

---@param items PullsComment[]
---@param comment PullsComment
local function upsert_comment(items, comment)
	for index, existing in ipairs(items) do
		if tostring(existing.id) == tostring(comment.id) then
			items[index] = comment
			return
		end
	end
	table.insert(items, comment)
end

---@param context AtlasReviewActionContext
---@param opts { parent: PullsComment|nil, inline: PullsInlineCommentPosition|nil, pending: boolean|nil, preview: AtlasMarkdownEditorPreview|nil }|nil
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.add_comment(context, opts, on_done)
	opts = opts or {}
	if not active(context) then
		return false
	end
	local parent = opts.parent
	if parent and parent.is_task then
		local message = "Tasks do not support replies"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local comments = context.provider.capabilities.comments
	local add = comments and comments.add_comment
	if not add then
		local message = "Provider does not support comments"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local pending = opts.pending == true or (parent ~= nil and parent.state == "PENDING")

	local completion = context.completion
	if completion == nil and context.items then
		completion = author_completion(context.provider, context.pr, context.items)
	end
	local mention = ""
	if parent and completion and completion.format_mention then
		mention = completion.format_mention(parent.author) or ""
	end
	local title = " Add Comment "
	if parent then
		title = " Reply to Comment "
	elseif pending then
		title = " Add Pending Comment "
	elseif opts.inline then
		title = " Add Inline Comment "
	end
	local preview = opts.preview
	if preview == nil and parent then
		preview = review_threads.render_comment(parent, math.max(math.floor(vim.o.columns * 0.5), 80))
	end

	open_editor(context, {
		key = "pr-comment",
		title = title,
		initial_text = mention ~= "" and (mention .. " ") or "",
		completion = completion,
		preview = preview,
		on_save = function(text)
			if not active(context) then
				return
			end
			if vim.trim(text) == "" then
				return
			end
			local message = parent and "Reply added" or "Comment added"
			notify(context, "loading", parent and "Sending reply..." or "Adding comment...")
			run_request(context, function(done)
				return add(context.pr, text, {
					parent = parent,
					inline = opts.inline,
					pending = pending,
				}, done)
			end, function(created, err)
				if not active(context) then
					return
				end
				if err then
					notify(context, "error", (parent and "Reply failed: " or "Add comment failed: ") .. err)
					on_done(nil, err)
					return
				end
				if created and context.items then
					upsert_comment(context.items, created)
				end
				notify(context, "success", message, 1200)
				on_done({ changed_pr = false, message = message }, nil)
			end)
		end,
	})
	return true
end

---@param items PullsComment[]
---@param comment PullsComment
local function remove_comment(items, comment)
	local id = tostring(comment.id)
	for _, existing in ipairs(items) do
		if tostring(existing.parent_id or "") == id then
			comment.content_raw = ""
			comment.deleted = true
			comment.state = "DELETED"
			return
		end
	end
	for index = #items, 1, -1 do
		local existing = items[index]
		if tostring(existing.id) == tostring(comment.id) then
			table.remove(items, index)
		end
	end
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.edit_comment(context, comment, on_done)
	if not active(context) then
		return false
	end
	local update
	if comment.is_task then
		local tasks = context.provider.capabilities.tasks
		update = tasks and tasks.edit_task
	else
		local comments = context.provider.capabilities.comments
		update = comments and comments.edit_comment
	end
	if not update then
		local message = "Provider does not support editing this item"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local items = assert(context.items)

	open_editor(context, {
		key = "pr-comment-edit",
		title = comment.is_task and " Edit Task " or " Edit Comment ",
		initial_text = comment.content_raw or "",
		on_save = function(text)
			if not active(context) then
				return
			end
			if vim.trim(text) == "" then
				return
			end
			notify(context, "loading", comment.is_task and "Editing task..." or "Editing comment...")
			local desired = vim.tbl_extend("force", {}, comment, { content_raw = text })
			run_request(context, function(done)
				if comment.is_task then
					return update(desired, done)
				end
				return update(context.pr, desired, done)
			end, function(updated, err)
				if not active(context) then
					return
				end
				if err then
					notify(context, "error", "Edit failed: " .. err)
					on_done(nil, err)
					return
				end
				local message = comment.is_task and "Task updated" or "Comment updated"
				notify(context, "success", message, 1200)
				if updated then
					upsert_comment(items, updated)
				end
				on_done({ changed_pr = false, message = message }, nil)
			end)
		end,
	})
	return true
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.delete_comment(context, comment, on_done)
	if not active(context) then
		return false
	end
	local remove
	if comment.is_task then
		local tasks = context.provider.capabilities.tasks
		remove = tasks and tasks.delete_task
	else
		local comments = context.provider.capabilities.comments
		remove = comments and comments.delete_comment
	end
	if not remove then
		local message = "Provider does not support deleting this item"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local items = assert(context.items)

	vim.ui.input({ prompt = comment.is_task and "Delete task? [y/N]: " or "Delete comment? [y/N]: " }, function(input)
		if not active(context) then
			return
		end
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify(context, "loading", comment.is_task and "Deleting task..." or "Deleting comment...")
		run_request(context, function(done)
			if comment.is_task then
				return remove(comment, done)
			end
			return remove(context.pr, comment, done)
		end, function(ok, err)
			if not active(context) then
				return
			end
			if err then
				notify(context, "error", "Delete failed: " .. err)
				on_done(nil, err)
				return
			end
			if not ok then
				notify(context, "error", "Delete failed")
				on_done(nil, "Delete failed")
				return
			end
			local message = comment.is_task and "Task deleted" or "Comment deleted"
			notify(context, "success", message, 1200)
			remove_comment(items, comment)
			on_done({ changed_pr = false, message = message }, nil)
		end)
	end)
	return true
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.toggle_task(context, comment, on_done)
	if not active(context) then
		return false
	end
	local tasks = context.provider.capabilities.tasks
	local update = tasks and tasks.edit_task
	if not update then
		local message = "Provider does not support tasks"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local items = assert(context.items)

	local is_resolved = comment.state == "RESOLVED"
	local desired = vim.deepcopy(comment)
	if is_resolved then
		desired.state = nil
	else
		desired.state = "RESOLVED"
	end
	notify(context, "loading", is_resolved and "Reopening task..." or "Resolving task...")
	run_request(context, function(done)
		return update(desired, done)
	end, function(updated, err)
		if not active(context) then
			return
		end
		if err then
			notify(context, "error", tostring(err))
			on_done(nil, tostring(err))
			return
		end
		local message = is_resolved and "Task reopened" or "Task resolved"
		notify(context, "success", message, 1200)
		if updated then
			upsert_comment(items, updated)
		end
		on_done({ changed_pr = false, message = message }, nil)
	end)
	return true
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.toggle_resolved(context, comment, on_done)
	if not active(context) then
		return false
	end
	local resolved = comment.state ~= "RESOLVED"
	local comments = context.provider.capabilities.comments
	local set_resolved = comments and comments.set_thread_resolved
	if not set_resolved then
		local message = "Provider does not support resolving threads"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	notify(context, "loading", resolved and "Resolving thread..." or "Reopening thread...")
	run_request(context, function(done)
		return set_resolved(context.pr, comment, resolved, done)
	end, function(ok, err)
		if not active(context) then
			return
		end
		if err or not ok then
			local message = tostring(err or "Unable to update thread")
			notify(context, "error", message)
			on_done(nil, message)
			return
		end
		local message = resolved and "Thread resolved" or "Thread reopened"
		notify(context, "success", message, 1200)
		comment.state = resolved and "RESOLVED" or nil
		on_done({ changed_pr = false, message = message }, nil)
	end)
	return true
end

---@param context AtlasReviewActionContext
---@param capability "submit_review"|"approve"|"request_changes"
---@param title string
---@param loading string
---@param success string
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
local function open_review_editor(context, capability, title, loading, success, on_done)
	if not active(context) then
		return false
	end
	local reviews = context.provider.capabilities.reviews
	local submit = reviews and reviews[capability]
	if not submit then
		local message = "Provider does not support this review action"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	open_editor(context, {
		key = "pr-review",
		title = title,
		on_save = function(body)
			if not active(context) then
				return
			end
			notify(context, "loading", loading)
			run_request(context, function(done)
				return submit(context.pr, body, done)
			end, function(ok, err)
				if not active(context) then
					return
				end
				if not ok then
					local message = vim.trim(title) .. " failed: " .. tostring(err or "Unknown error")
					notify(context, "error", message)
					on_done(nil, err)
					return
				end
				notify(context, "success", success, 1200)
				on_done({ changed_pr = true, message = success }, nil)
			end)
		end,
	})
	return true
end

M.submit_review = {
	id = "submit_review",
	label = "Submit review",
	run = function(context, on_done)
		return open_review_editor(
			context,
			"submit_review",
			" Submit Review ",
			"Submitting review...",
			"Review submitted",
			on_done
		)
	end,
}

M.approve = {
	id = "approve",
	label = "Approve",
	run = function(context, on_done)
		return open_review_editor(context, "approve", " Approve ", "Approving...", "Approved", on_done)
	end,
}

M.request_changes = {
	id = "request_changes",
	label = "Request changes",
	run = function(context, on_done)
		return open_review_editor(
			context,
			"request_changes",
			" Request Changes ",
			"Requesting changes...",
			"Changes requested",
			on_done
		)
	end,
}

return M
