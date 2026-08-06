local M = {}

local editor = require("atlas.ui.popups.editor")
local statusline = require("atlas.ui.statusline")
local pull_actions = require("atlas.pulls.actions")
local review_threads = require("atlas.ui.components.review_threads")

---@alias AtlasReviewCommentAction "reply"|"edit"|"delete"|"toggle_task"|"toggle_resolved"

---@param provider PullsProvider|nil
---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@return function|nil
local function action_handler(provider, action, comment)
	if not provider then
		return nil
	end
	local comments = provider.capabilities.comments
	local reviews = provider.capabilities.reviews
	if action == "edit" then
		if comment.is_task then
			return reviews and reviews.edit_task
		end
		return comments and comments.edit_comment
	end
	if action == "delete" then
		if comment.is_task then
			return reviews and reviews.delete_task
		end
		return comments and comments.delete_comment
	end
	if action == "toggle_task" then
		return reviews and reviews.edit_task
	end
	if action == "reply" then
		return comments and comments.add_comment
	end
	return reviews and reviews.set_thread_resolved
end

---@class AtlasReviewCommentActionContext
---@field provider PullsProvider
---@field pr PullRequest
---@field current_user PullsUser|nil
---@field items PullsComment[]
---@field completion AtlasMarkdownCompletionProvider|nil
---@field active (fun(): boolean)|nil
---@field track fun(handle: { cancel: fun() }|nil): fun()
---@field refresh fun()
---@field reload (fun())|nil
---@field notify fun(level: "loading"|"success"|"info"|"warn"|"error", message: string, duration: integer|nil)|nil

---@class AtlasReviewAddOptions
---@field pending boolean|nil
---@field preview AtlasMarkdownEditorPreview|nil
---@field initial_text string|nil
---@field kind "comment"|"suggestion"|nil

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

---@param comment PullsComment
---@param current_user PullsUser|nil
---@return boolean
local function is_own_comment(comment, current_user)
	if not current_user or not comment.author then
		return false
	end
	local author_id = tostring(comment.author.id or "")
	local user_id = tostring(current_user.id or "")
	return author_id ~= "" and user_id ~= "" and author_id == user_id
end

---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@param current_user PullsUser|nil
---@param provider PullsProvider|nil
---@return boolean
function M.is_available(action, comment, current_user, provider)
	if comment.state == "DELETED" then
		return false
	end
	if action == "reply" and comment.is_task then
		return false
	end
	if action == "toggle_task" and not comment.is_task then
		return false
	end
	if action == "toggle_resolved" then
		if comment.is_task or comment.state == "PENDING" or comment.can_resolve == false then
			return false
		end
	end
	if (action == "edit" or action == "delete") and not is_own_comment(comment, current_user) then
		return false
	end
	return action_handler(provider, action, comment) ~= nil
end

---@param context AtlasReviewCommentActionContext
---@param opts AtlasMarkdownEditorOptions
local function open_editor(context, opts)
	opts.width_ratio = 0.5
	opts.height_ratio = 0.18
	opts.completion = opts.completion
		or context.completion
		or author_completion(context.provider, context.pr, context.items)
	editor.open(opts)
end

---@param context AtlasReviewCommentActionContext
---@param level "loading"|"success"|"info"|"warn"|"error"
---@param message string
---@param duration integer|nil
local function notify(context, level, message, duration)
	if context.notify then
		context.notify(level, message, duration)
		return
	end
	statusline.notify(level, message, duration)
end

---@param context AtlasReviewCommentActionContext
---@return boolean
local function active(context)
	return context.active == nil or context.active()
end

---@param provider PullsProvider|nil
---@return boolean
function M.can_submit(provider)
	local reviews = provider and provider.capabilities.reviews
	return reviews ~= nil and reviews.submit_review ~= nil
end

---@param pr PullRequest
---@return boolean
function M.can_toggle_approval(pr)
	return pull_actions.is_action_available(pr, "toggle_approval")
end

---@param context AtlasReviewCommentActionContext
---@param action_id string
local function run_pull_action(context, action_id)
	pull_actions.run_action(context.pr, action_id, {
		source = "diff",
		current_user = context.current_user,
		notify = context.notify,
	}, function(result, err)
		if not active(context) or err or not result then
			return
		end
		if not result.changed_pr then
			notify(context, "info", tostring(result.message or "Action cancelled"), 1200)
			return
		end
		if context.reload then
			context.reload()
		else
			context.refresh()
		end
	end)
end

---@param pr PullRequest
---@return boolean
function M.can_request_changes(pr)
	return pull_actions.is_action_available(pr, "request_changes")
end

---@param context AtlasReviewCommentActionContext
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
	release = context.track(start(complete))
	if finished then
		release()
	end
end

---@param context AtlasReviewCommentActionContext
---@return boolean handled
function M.submit(context)
	local provider = context.provider
	if not active(context) or not M.can_submit(provider) then
		return false
	end
	local submit_review = provider.capabilities.reviews.submit_review
	---@cast submit_review function
	open_editor(context, {
		key = "pr-review-submit-" .. tostring(context.pr.id),
		title = " Submit Review ",
		on_save = function(body)
			if not active(context) then
				return
			end
			notify(context, "loading", "Submitting review...", nil)
			run_request(context, function(done)
				return submit_review(context.pr, body, done)
			end, function(ok, err)
				if not active(context) then
					return
				end
				if err or not ok then
					notify(context, "error", "Submit review failed: " .. tostring(err or "Unknown error"), nil)
					return
				end
				notify(context, "success", "Review submitted", 1200)
				if context.reload then
					context.reload()
				else
					context.refresh()
				end
			end)
		end,
	})
	return true
end

---@param context AtlasReviewCommentActionContext
function M.toggle_approval(context)
	if not active(context) or not M.can_toggle_approval(context.pr) then
		return
	end
	run_pull_action(context, "toggle_approval")
end

---@param context AtlasReviewCommentActionContext
function M.request_changes(context)
	if not active(context) or not M.can_request_changes(context.pr) then
		return
	end
	run_pull_action(context, "request_changes")
end

---@param context AtlasReviewCommentActionContext
---@param inline PullsInlineCommentPosition|nil
---@param opts AtlasReviewAddOptions|nil
---@return boolean handled
function M.add(context, inline, opts)
	local provider = context.provider
	local comments = provider.capabilities.comments
	local add_comment = comments and comments.add_comment
	if not active(context) or not add_comment then
		return false
	end
	opts = opts or {}
	local pending = opts.pending == true
	local suggestion = opts.kind == "suggestion"
	local noun = suggestion and "suggestion" or "comment"

	local key =
		string.format("pr-comment-add-%s-%s-%s", tostring(context.pr.id or ""), pending and "pending" or "now", noun)
	if inline then
		key = string.format(
			"%s-%s-%s-%s-%s",
			key,
			tostring(inline.start_from or ""),
			tostring(inline.start_to or ""),
			tostring(inline.from or ""),
			tostring(inline.to or "")
		)
	end
	local title
	if suggestion then
		title = pending and " Add Pending Suggestion " or " Add Suggestion "
	elseif pending then
		title = " Add Pending Comment "
	elseif inline then
		title = " Add Inline Comment "
	else
		title = " Add Comment "
	end
	open_editor(context, {
		key = key,
		title = title,
		initial_text = opts.initial_text,
		preview = opts.preview,
		on_save = function(text)
			if not active(context) or not text or vim.trim(text) == "" then
				return
			end
			notify(context, "loading", "Adding " .. noun .. "...", nil)
			run_request(context, function(done)
				return add_comment(context.pr, text, { inline = inline, pending = pending }, done)
			end, function(created, err)
				if not active(context) then
					return
				end
				if err then
					notify(context, "error", "Add " .. noun .. " failed: " .. err, nil)
					return
				end
				if created then
					table.insert(context.items, created)
				end
				notify(context, "success", suggestion and "Suggestion added" or "Comment added", 1200)
				context.refresh()
			end)
		end,
	})
	return true
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
local function upsert_comment(context, comment)
	for index, existing in ipairs(context.items) do
		if tostring(existing.id) == tostring(comment.id) then
			context.items[index] = comment
			return
		end
	end
	table.insert(context.items, comment)
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
local function remove_comment(context, comment)
	local id = tostring(comment.id)
	for _, existing in ipairs(context.items) do
		if tostring(existing.parent_id or "") == id then
			comment.content_raw = ""
			comment.deleted = true
			comment.state = "DELETED"
			return
		end
	end
	for index = #context.items, 1, -1 do
		local existing = context.items[index]
		if tostring(existing.id) == tostring(comment.id) then
			table.remove(context.items, index)
		end
	end
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
---@return boolean handled
local function reply(context, comment)
	local provider = context.provider
	if not active(context) or not M.is_available("reply", comment, context.current_user, provider) then
		return false
	end
	local add_comment = action_handler(provider, "reply", comment)
	---@cast add_comment function

	local completion = context.completion or author_completion(provider, context.pr, context.items)
	local mention = ""
	if completion and completion.format_mention then
		mention = completion.format_mention(comment.author) or ""
	end
	open_editor(context, {
		key = "pr-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		initial_text = mention ~= "" and (mention .. " ") or "",
		completion = completion,
		preview = review_threads.render_comment(comment, math.max(math.floor(vim.o.columns * 0.5), 80)),
		on_save = function(text)
			if not active(context) or not text or vim.trim(text) == "" then
				return
			end
			notify(context, "loading", "Sending reply...", nil)
			run_request(context, function(done)
				return add_comment(context.pr, text, {
					parent = comment,
					pending = comment.state == "PENDING",
				}, done)
			end, function(created, err)
				if not active(context) then
					return
				end
				if err then
					notify(context, "error", "Reply failed: " .. err, nil)
					return
				end
				if created then
					if created.parent_id == nil then
						created.parent_id = comment.parent_id or comment.id
					end
					table.insert(context.items, created)
				end
				notify(context, "success", "Reply added", 1200)
				context.refresh()
			end)
		end,
	})
	return true
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
---@return boolean handled
local function edit(context, comment)
	local provider = context.provider
	if not active(context) or not M.is_available("edit", comment, context.current_user, provider) then
		return false
	end
	local update = action_handler(provider, "edit", comment)
	---@cast update function

	open_editor(context, {
		key = "pr-comment-edit-" .. tostring(comment.id),
		title = comment.is_task and " Edit Task " or " Edit Comment ",
		initial_text = comment.content_raw or "",
		on_save = function(text)
			if not active(context) or not text or vim.trim(text) == "" then
				return
			end
			notify(context, "loading", comment.is_task and "Editing task..." or "Editing comment...", nil)
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
					notify(context, "error", "Edit failed: " .. err, nil)
					return
				end
				notify(context, "success", comment.is_task and "Task updated" or "Comment updated", 1200)
				upsert_comment(context, vim.tbl_extend("keep", updated or {}, desired))
				context.refresh()
			end)
		end,
	})
	return true
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
---@return boolean handled
local function delete(context, comment)
	local provider = context.provider
	if not active(context) or not M.is_available("delete", comment, context.current_user, provider) then
		return false
	end
	local remove = action_handler(provider, "delete", comment)
	---@cast remove function

	vim.ui.input({ prompt = comment.is_task and "Delete task? [y/N]: " or "Delete comment? [y/N]: " }, function(input)
		if not active(context) then
			return
		end
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify(context, "loading", comment.is_task and "Deleting task..." or "Deleting comment...", nil)
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
				notify(context, "error", "Delete failed: " .. err, nil)
				return
			end
			if not ok then
				notify(context, "error", "Delete failed", nil)
				return
			end
			notify(context, "success", comment.is_task and "Task deleted" or "Comment deleted", 1200)
			remove_comment(context, comment)
			context.refresh()
		end)
	end)
	return true
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
---@return boolean handled
local function toggle_task(context, comment)
	if not active(context) then
		return false
	end
	if not comment.is_task then
		notify(context, "warn", "Not a task", nil)
		return false
	end
	local provider = context.provider
	if not M.is_available("toggle_task", comment, context.current_user, provider) then
		return false
	end
	local update = action_handler(provider, "toggle_task", comment)
	---@cast update function

	local is_resolved = comment.state == "RESOLVED"
	local desired = vim.deepcopy(comment)
	if is_resolved then
		desired.state = nil
	else
		desired.state = "RESOLVED"
	end
	notify(context, "loading", is_resolved and "Reopening task..." or "Resolving task...", nil)
	run_request(context, function(done)
		return update(desired, done)
	end, function(updated, err)
		if not active(context) then
			return
		end
		if err then
			notify(context, "error", tostring(err), nil)
			return
		end
		notify(context, "success", is_resolved and "Task reopened" or "Task resolved", 1200)
		upsert_comment(context, vim.tbl_extend("keep", updated or {}, desired))
		context.refresh()
	end)
	return true
end

---@param context AtlasReviewCommentActionContext
---@param comment PullsComment
---@return boolean handled
local function toggle_resolved(context, comment)
	local provider = context.provider
	if not active(context) or not M.is_available("toggle_resolved", comment, context.current_user, provider) then
		return false
	end

	local resolved = comment.state ~= "RESOLVED"
	local set_resolved = action_handler(provider, "toggle_resolved", comment)
	---@cast set_resolved function
	notify(context, "loading", resolved and "Resolving thread..." or "Reopening thread...", nil)
	run_request(context, function(done)
		return set_resolved(context.pr, comment, resolved, done)
	end, function(ok, err)
		if not active(context) then
			return
		end
		if err or not ok then
			notify(context, "error", tostring(err or "Unable to update thread"), nil)
			return
		end
		notify(context, "success", resolved and "Thread resolved" or "Thread reopened", 1200)
		comment.state = resolved and "RESOLVED" or nil
		context.refresh()
	end)
	return true
end

---@param context AtlasReviewCommentActionContext
---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@return boolean handled
function M.run(context, action, comment)
	if action == "reply" then
		return reply(context, comment)
	end
	if action == "edit" then
		return edit(context, comment)
	end
	if action == "delete" then
		return delete(context, comment)
	end
	if action == "toggle_task" then
		return toggle_task(context, comment)
	end
	if action == "toggle_resolved" then
		return toggle_resolved(context, comment)
	end
	return false
end

return M
