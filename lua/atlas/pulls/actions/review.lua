local M = {}

local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local editor = require("atlas.ui.popups.editor")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local ui_utils = require("atlas.ui.utils")
local review_threads = require("atlas.pulls.ui.components.review_threads")

---@class AtlasReviewActionContext: AtlasPullActionContext
---@field pr PullRequest
---@field items PullsComment[]|nil
---@field data PullsReviewData|nil
---@field completion AtlasMarkdownCompletionProvider|nil
---@field upsert_comment (fun(comment: PullsComment))|nil
---@field remove_comment (fun(comment: PullsComment))|nil

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

---@return AtlasMarkdownEditorAction|nil
local function comment_template_action()
	local templates = config.options.pulls.comment_templates.items
	local key = (keymaps.resolve("pulls.review.comment_templates") or {})[1]
	if #templates == 0 or not key then
		return nil
	end
	local label_width = 0
	for _, template in ipairs(templates) do
		label_width = math.max(label_width, vim.fn.strdisplaywidth(template.label))
	end
	return {
		key = key,
		description = "templates",
		callback = function(context)
			picker.select({
				title = "Comment templates",
				items = templates,
				format_item = function(template)
					return ui_utils.pad_right(template.label, label_width) .. "  " .. template.text
				end,
				on_select = function(template)
					if template then
						context.set_text(template.text .. context.get_text())
						vim.cmd("startinsert!")
					end
				end,
			})
		end,
	}
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
local function upsert_comment(context, comment)
	if context.upsert_comment then
		context.upsert_comment(comment)
		return
	end
	local items = assert(context.items)
	for index, existing in ipairs(items) do
		if tostring(existing.id) == tostring(comment.id) then
			items[index] = comment
			return
		end
	end
	table.insert(items, comment)
end

---@param context AtlasReviewActionContext
---@param opts { parent: PullsComment|nil, inline: PullsInlineCommentPosition|nil, file: PullsFileCommentPosition|nil, pending: boolean|nil, preview: AtlasMarkdownEditorPreview|nil, initial_text: string|nil, kind: "comment"|"suggestion"|nil }|nil
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.add_comment(context, opts, on_done)
	opts = opts or {}
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
	local suggestion = opts.kind == "suggestion"

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
	elseif suggestion then
		title = pending and " Add Pending Suggestion " or " Add Suggestion "
	elseif opts.file then
		title = pending and " Add Pending File Comment " or " Add File Comment "
	elseif pending then
		title = " Add Pending Comment "
	elseif opts.inline then
		title = " Add Inline Comment "
	end
	local preview = opts.preview
	if preview == nil and parent then
		preview = review_threads.render_comment(parent, math.max(math.floor(vim.o.columns * 0.5), 80))
	end
	local template_action = comment_template_action()

	open_editor(context, {
		key = "pr-comment",
		title = title,
		initial_text = opts.initial_text or (mention ~= "" and (mention .. " ") or ""),
		completion = completion,
		preview = preview,
		actions = template_action and { template_action } or nil,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end
			local message = parent and "Reply added" or suggestion and "Suggestion added" or "Comment added"
			notify(
				context,
				"loading",
				parent and "Sending reply..." or suggestion and "Adding suggestion..." or "Adding comment..."
			)
			add(context.pr, text, {
				parent = parent,
				inline = opts.inline,
				file = opts.file,
				pending = pending,
				review = context.data and context.data.review,
			}, function(created, err)
				if err then
					local prefix = parent and "Reply failed: "
						or suggestion and "Add suggestion failed: "
						or "Add comment failed: "
					notify(context, "error", prefix .. err)
					on_done(nil, err)
					return
				end
				if created then
					upsert_comment(context, created)
				end
				if pending and context.data then
					context.data.review.pending = true
				end
				notify(context, "success", message, 1200)
				on_done({ changed_pr = false, message = message }, nil)
			end)
		end,
	})
	return true
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
local function remove_comment(context, comment)
	local items = assert(context.items)
	local id = tostring(comment.id)
	for _, existing in ipairs(items) do
		if tostring(existing.parent_id or "") == id then
			comment.content_raw = ""
			comment.state = "DELETED"
			if context.upsert_comment then
				context.upsert_comment(comment)
			end
			return
		end
	end
	if context.remove_comment then
		context.remove_comment(comment)
		return
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
	open_editor(context, {
		key = "pr-comment-edit",
		title = comment.is_task and " Edit Task " or " Edit Comment ",
		initial_text = comment.content_raw or "",
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end
			notify(context, "loading", comment.is_task and "Editing task..." or "Editing comment...")
			local desired = vim.tbl_extend("force", {}, comment, { content_raw = text })
			local callback = function(updated, err)
				if err then
					notify(context, "error", "Edit failed: " .. err)
					on_done(nil, err)
					return
				end
				local message = comment.is_task and "Task updated" or "Comment updated"
				notify(context, "success", message, 1200)
				if updated then
					upsert_comment(context, updated)
				end
				on_done({ changed_pr = false, message = message }, nil)
			end
			if comment.is_task then
				update(desired, callback)
			else
				update(context.pr, desired, callback)
			end
		end,
	})
	return true
end

---@param context AtlasReviewActionContext
---@param entry PullsReviewHistoryEntry
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.edit_review(context, entry, on_done)
	local reviews = context.provider.capabilities.reviews
	local update = reviews and reviews.edit_review
	if not update or not entry.id or vim.trim(entry.body or "") == "" then
		local message = "This review cannot be edited"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end

	open_editor(context, {
		key = "pr-review-edit",
		title = " Edit Review ",
		initial_text = entry.body or "",
		on_save = function(text)
			notify(context, "loading", "Editing review...")
			update(context.pr, entry.id, text, function(ok, err)
				if err or not ok then
					err = err or "Failed to update review"
					notify(context, "error", "Edit failed: " .. err)
					on_done(nil, err)
					return
				end
				entry.body = text
				notify(context, "success", "Review updated", 1200)
				on_done({ changed_pr = false, message = "Review updated" }, nil)
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
	vim.ui.input({ prompt = comment.is_task and "Delete task? [y/N]: " or "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify(context, "loading", comment.is_task and "Deleting task..." or "Deleting comment...")
		local callback = function(ok, err)
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
			local pending = comment.state == "PENDING"
			local message = comment.is_task and "Task deleted" or "Comment deleted"
			if pending and context.data then
				context.provider.capabilities.reviews.fetch(context.pr, { force_refresh = true }, function(data)
					if data then
						context.data.review = data.review
						context.data.comments = data.comments
						context.data.tasks = data.tasks
						context.data.reviewers = data.reviewers
						context.data.history = data.history
					else
						remove_comment(context, comment)
					end
					notify(context, "success", message, 1200)
					on_done({ changed_pr = false, message = message }, nil)
				end)
				return
			end
			remove_comment(context, comment)
			notify(context, "success", message, 1200)
			on_done({ changed_pr = false, message = message }, nil)
		end
		if comment.is_task then
			remove(comment, callback)
		else
			remove(context.pr, comment, callback)
		end
	end)
	return true
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.toggle_task(context, comment, on_done)
	local tasks = context.provider.capabilities.tasks
	local update = tasks and tasks.edit_task
	if not update then
		local message = "Provider does not support tasks"
		notify(context, "error", message)
		on_done(nil, message)
		return false
	end
	local is_resolved = comment.state == "RESOLVED"
	local desired = vim.deepcopy(comment)
	if is_resolved then
		desired.state = nil
	else
		desired.state = "RESOLVED"
	end
	notify(context, "loading", is_resolved and "Reopening task..." or "Resolving task...")
	update(desired, function(updated, err)
		if err then
			notify(context, "error", tostring(err))
			on_done(nil, tostring(err))
			return
		end
		local message = is_resolved and "Task reopened" or "Task resolved"
		notify(context, "success", message, 1200)
		if updated then
			upsert_comment(context, updated)
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
	set_resolved(context.pr, comment, resolved, function(ok, err)
		if err or not ok then
			local message = tostring(err or "Unable to update thread")
			notify(context, "error", message)
			on_done(nil, message)
			return
		end
		local message = resolved and "Thread resolved" or "Thread reopened"
		notify(context, "success", message, 1200)
		comment.state = resolved and "RESOLVED" or (comment.outdated and "OUTDATED" or nil)
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
			notify(context, "loading", loading)
			submit(context.pr, context.data and context.data.review, body, function(ok, err)
				if not ok then
					local message = vim.trim(title) .. " failed: " .. tostring(err or "Unknown error")
					notify(context, "error", message)
					on_done(nil, err)
					return
				end
				notify(context, "success", success, 1200)
				if capability == "approve" then
					notes.clear_for_pull_request(context.pr)
				end
				on_done({ changed_pr = true, message = success }, nil)
			end)
		end,
	})
	return true
end

M.start_review = {
	id = "start_review",
	label = "Start review",
	run = function(context, on_done)
		local data = context.data
		local reviews = context.provider.capabilities.reviews
		local start = reviews and reviews.start_review
		if not data or data.review.pending or not start then
			return false
		end
		notify(context, "loading", "Starting review...")
		start(context.pr, data.review, function(ok, err)
			if not ok then
				local message = tostring(err or "Unknown error")
				notify(context, "error", "Start review failed: " .. message)
				on_done(nil, message)
				return
			end
			notify(context, "success", "Review started", 1200)
			on_done({ changed_pr = false, message = "Review started" }, nil)
		end)
		return true
	end,
}

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

M.discard_review = {
	id = "discard_review",
	label = "Discard review",
	run = function(context, on_done)
		local data = context.data
		local reviews = context.provider.capabilities.reviews
		local discard = reviews and reviews.discard_review
		if not data or not data.review.pending or not discard then
			return false
		end
		vim.ui.input({ prompt = "Discard pending review? [y/N]: " }, function(input)
			if not input or not input:lower():match("^y") then
				return
			end
			notify(context, "loading", "Discarding review...")
			discard(context.pr, data.review, function(ok, err)
				if not ok then
					notify(context, "error", "Discard review failed: " .. tostring(err or "Unknown error"))
					on_done(nil, err)
					return
				end
				data.review.id = nil
				data.review.commit_hash = nil
				data.review.pending = false
				for _, items in ipairs({ data.comments, data.tasks }) do
					for index = #items, 1, -1 do
						if items[index].state == "PENDING" then
							table.remove(items, index)
						end
					end
				end
				notify(context, "success", "Review discarded", 1200)
				on_done({ changed_pr = false, message = "Review discarded" }, nil)
			end)
		end)
		return true
	end,
}

return M
