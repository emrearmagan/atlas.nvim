local M = {}

local config = require("atlas.config")
local completion = require("atlas.completion")
local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local editor = require("atlas.ui.popups.editor")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local ui_utils = require("atlas.ui.utils")
local comment_threads = require("atlas.pulls.ui.components.comment_threads")

---@class AtlasReviewActionContext: AtlasPullActionContext
---@field pr PullRequest
---@field data PullsReviewData|nil
---@field comment PullsComment|nil
---@field review_entry PullsReviewHistoryEntry|nil
---@field draft { inline?: PullsInlineCommentPosition, file?: PullsFileCommentPosition, pending?: boolean, preview?: AtlasEditorPreview, initial_text?: string, kind?: "comment"|"suggestion" }|nil
---@field conversation PullsComment[]|nil
---@field on_submit (fun())|nil
---@field upsert_comment (fun(comment: PullsComment))|nil
---@field remove_comment (fun(comment: PullsComment))|nil

---@param comments PullsComment[]
---@param tasks PullsComment[]|nil
---@return AtlasCommentThreadNode[]
function M.group_comments(comments, tasks)
	local items = vim.list_extend({}, comments)
	if tasks then
		vim.list_extend(items, tasks)
	end

	table.sort(items, function(a, b)
		if a.created_at ~= b.created_at then
			return a.created_at < b.created_at
		end
		return tostring(a.id) < tostring(b.id)
	end)

	local nodes, by_id = {}, {}
	for _, comment in ipairs(items) do
		local node = { comment = comment, children = {} }
		nodes[#nodes + 1] = node

		-- Tasks and comments can have the same ID.
		local key = (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
		by_id[key] = node
	end

	local roots = {}
	for _, node in ipairs(nodes) do
		local parent_id = node.comment.parent_id
		local parent = parent_id and by_id["comment:" .. tostring(parent_id)]
		if parent and parent ~= node then
			parent.children[#parent.children + 1] = node
		else
			roots[#roots + 1] = node
		end
	end

	local function prune_deleted(list)
		for index = #list, 1, -1 do
			local node = list[index]
			prune_deleted(node.children)
			if node.comment.deleted and #node.children == 0 then
				table.remove(list, index)
			end
		end
	end
	prune_deleted(roots)

	return roots
end

---@param context AtlasReviewActionContext
---@param opts AtlasEditorOptions
local function open_editor(context, opts)
	opts.width_ratio = 0.7
	opts.height_ratio = 0.5
	opts.completion = {
		context = {
			provider = context.provider.id,
			repository = context.pr.repo_full_name,
			pr = { id = context.pr.id, repo_full_name = context.pr.repo_full_name },
		},
	}
	local on_save, on_submit = opts.on_save, context.on_submit
	if on_save and on_submit then
		opts.on_save = function(text)
			on_submit()
			on_save(text)
		end
	end
	editor.open(opts)
end

---@return AtlasEditorAction|nil
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
						if config.options.pulls.comment_templates.insert_mode then
							vim.cmd("startinsert!")
						end
					end
				end,
			})
		end,
	}
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
---@return PullsComment[]
local function comment_items(context, comment)
	local data = assert(context.data)
	return comment.is_task and data.tasks or data.comments
end

---@param context AtlasReviewActionContext
---@param task_key "edit_task"|"delete_task"
---@param comment_key "edit_comment"|"delete_comment"
---@return function|nil
local function item_capability(context, task_key, comment_key)
	local comment = assert(context.comment)
	local capabilities = context.provider.capabilities
	local capability = comment.is_task and capabilities.tasks or capabilities.comments
	return capability and capability[comment.is_task and task_key or comment_key]
end

---@param context AtlasReviewActionContext
---@param comment PullsComment
local function upsert_comment(context, comment)
	if context.upsert_comment then
		context.upsert_comment(comment)
		return
	end
	local items = comment_items(context, comment)
	for index, existing in ipairs(items) do
		if tostring(existing.id) == tostring(comment.id) then
			comment.hunk = comment.hunk or existing.hunk
			items[index] = comment
			return
		end
	end
	table.insert(items, comment)
end

M.add_comment = {
	id = "add_comment",
	label = "Add comment",
	icon = icons.get("comment"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if context.comment and context.comment.is_task then
			return false, "Tasks do not support replies"
		end
		local comments = context.provider.capabilities.comments
		return comments ~= nil and comments.add_comment ~= nil, "Provider does not support comments"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local opts = context.draft or {}
		local parent = context.comment
		local add = assert(context.provider.capabilities.comments.add_comment)
		local pending = opts.pending == true or (parent ~= nil and parent.pending == true)
		local suggestion = opts.kind == "suggestion"

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
			preview = comment_threads.render_comment(parent, math.max(math.floor(vim.o.columns * 0.7), 80))
		end
		local template_action = comment_template_action()
		local mention = parent and completion.format_mention(context.provider, parent.author)

		open_editor(context, {
			key = "pr-comment",
			title = title,
			initial_text = opts.initial_text or (mention and (mention .. " ")),
			preview = preview,
			actions = template_action and { template_action } or nil,
			on_save = function(text)
				if vim.trim(text) == "" then
					return
				end
				local message = parent and "Reply added" or suggestion and "Suggestion added" or "Comment added"
				notify.loading(
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
						notify.error(prefix .. err)
						on_done(nil, err)
						return
					end
					if created then
						upsert_comment(context, created)
					end
					if pending and context.data then
						context.data.review.pending = true
					end
					notify.success(message, { timeout = 1200 })
					on_done({ changed_pr = false }, nil)
				end)
			end,
		})
		return true
	end,
}

M.add_task = {
	id = "add_task",
	label = "Add task",
	icon = icons.get("checkbox_unchecked"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if context.comment and context.comment.is_task then
			return false, "Tasks cannot have child tasks"
		end
		local tasks = context.provider.capabilities.tasks
		return tasks ~= nil and tasks.add_task ~= nil, "Provider does not support tasks"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local parent = context.comment
		local add = assert(context.provider.capabilities.tasks.add_task)
		open_editor(context, {
			key = "pr-task-add-" .. tostring(context.pr.id),
			title = " Add Task ",
			preview = parent and comment_threads.render_comment(parent, math.max(math.floor(vim.o.columns * 0.7), 80)),
			on_save = function(text)
				if vim.trim(text) == "" then
					notify.warn("Task cannot be empty")
					return
				end

				notify.loading("Adding task...")
				add(context.pr, text, parent, function(task, err)
					if err then
						notify.error(tostring(err))
						on_done(nil, err)
						return
					end

					if task then
						upsert_comment(context, task)
						if task.pending and context.data then
							context.data.review.pending = true
						end
					end

					local message = "Task added"
					notify.success(message, { timeout = 1200 })
					on_done({ changed_pr = false }, nil)
				end)
			end,
		})
		return true
	end,
}

---@param context AtlasReviewActionContext
---@param comment PullsComment
local function remove_comment(context, comment)
	if not comment.is_task then
		local data = context.data
		local children = data and vim.list_extend(vim.list_extend({}, data.comments), data.tasks)
			or context.conversation
			or {}
		local id = tostring(comment.id)
		for _, existing in ipairs(children) do
			if tostring(existing.parent_id or "") == id then
				comment.body = ""
				comment.body_display = nil
				comment.deleted = true
				comment.pending = false
				upsert_comment(context, comment)
				return
			end
		end
	end
	if context.remove_comment then
		context.remove_comment(comment)
		return
	end
	local items = comment_items(context, comment)
	for index = #items, 1, -1 do
		local existing = items[index]
		if tostring(existing.id) == tostring(comment.id) then
			table.remove(items, index)
		end
	end
end

M.edit_comment = {
	id = "edit_comment",
	label = "Edit comment",
	icon = icons.get("edit", "actions"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if not context.comment or context.comment.deleted then
			return false, "No comment selected"
		end
		return item_capability(context, "edit_task", "edit_comment") ~= nil,
			"Provider does not support editing this item"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local comment = assert(context.comment)
		local update = assert(item_capability(context, "edit_task", "edit_comment"))
		open_editor(context, {
			key = "pr-comment-edit",
			title = comment.is_task and " Edit Task " or " Edit Comment ",
			initial_text = comment.body or "",
			on_save = function(text)
				if vim.trim(text) == "" then
					return
				end
				notify.loading(comment.is_task and "Editing task..." or "Editing comment...")
				local callback = function(updated, err)
					if err then
						notify.error("Edit failed: " .. err)
						on_done(nil, err)
						return
					end
					local message = comment.is_task and "Task updated" or "Comment updated"
					notify.success(message, { timeout = 1200 })
					if updated then
						upsert_comment(context, updated)
					end
					on_done({ changed_pr = false }, nil)
				end
				if comment.is_task then
					local desired = vim.tbl_extend("force", {}, comment, { body = text })
					desired.body_display = nil
					update(desired, callback)
				else
					update(context.pr, comment, text, callback)
				end
			end,
		})
		return true
	end,
}

M.edit_review = {
	id = "edit_review",
	label = "Edit review",
	icon = icons.get("edit", "actions"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		local entry = context.review_entry
		local reviews = context.provider.capabilities.reviews
		local editable = entry ~= nil and entry.id ~= nil and vim.trim(entry.body or "") ~= ""
		return editable and reviews ~= nil and reviews.edit_review ~= nil, "This review cannot be edited"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local entry = assert(context.review_entry)
		local update = assert(context.provider.capabilities.reviews.edit_review)
		open_editor(context, {
			key = "pr-review-edit",
			title = " Edit Review ",
			initial_text = entry.body or "",
			on_save = function(text)
				notify.loading("Editing review...")
				update(context.pr, entry.id, text, function(ok, err)
					if err or not ok then
						err = err or "Failed to update review"
						notify.error("Edit failed: " .. err)
						on_done(nil, err)
						return
					end
					entry.body = text
					notify.success("Review updated", { timeout = 1200 })
					on_done({ changed_pr = false }, nil)
				end)
			end,
		})
		return true
	end,
}

---@param data PullsReviewData
---@param target PullsComment
---@return boolean
local function has_other_pending_items(data, target)
	local target_kind = target.is_task and "tasks" or "comments"
	for _, kind in ipairs({ "comments", "tasks" }) do
		for _, item in ipairs(data[kind] or {}) do
			local is_target = kind == target_kind and tostring(item.id) == tostring(target.id)
			if item.pending and not is_target then
				return true
			end
		end
	end
	return false
end

M.delete_comment = {
	id = "delete_comment",
	label = "Delete comment",
	icon = icons.get("delete", "actions"),
	---@param context AtlasReviewActionContext
	confirm = function(context)
		return context.comment.is_task and "Delete task?" or "Delete comment?"
	end,
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if not context.comment or context.comment.deleted then
			return false, "No comment selected"
		end
		return item_capability(context, "delete_task", "delete_comment") ~= nil,
			"Provider does not support deleting this item"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local comment = assert(context.comment)
		local remove = assert(item_capability(context, "delete_task", "delete_comment"))
		if context.on_submit then
			context.on_submit()
		end
		notify.loading(comment.is_task and "Deleting task..." or "Deleting comment...")
		local callback = function(ok, err)
			if err then
				notify.error("Delete failed: " .. err)
				on_done(nil, err)
				return
			end
			if not ok then
				notify.error("Delete failed")
				on_done(nil, "Delete failed")
				return
			end
			-- Deleting the final pending item can also remove its draft review.
			local review_changed = comment.pending
				and context.data ~= nil
				and not has_other_pending_items(context.data, comment)
			remove_comment(context, comment)
			notify.success(comment.is_task and "Task deleted" or "Comment deleted", { timeout = 1200 })
			on_done({ changed_pr = review_changed == true }, nil)
		end
		if comment.is_task then
			remove(comment, callback)
		else
			remove(context.pr, comment, callback)
		end
		return true
	end,
}

M.toggle_task = {
	id = "toggle_task",
	label = "Toggle task",
	icon = icons.get("checkbox_checked"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if not context.comment then
			return false, "No task selected"
		end
		local tasks = context.provider.capabilities.tasks
		return tasks ~= nil and tasks.edit_task ~= nil, "Provider does not support tasks"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local comment = assert(context.comment)
		local update = assert(context.provider.capabilities.tasks.edit_task)
		if context.on_submit then
			context.on_submit()
		end
		local is_resolved = comment.state == "RESOLVED"
		local desired = vim.deepcopy(comment)
		if is_resolved then
			desired.state = nil
		else
			desired.state = "RESOLVED"
		end
		notify.loading(is_resolved and "Reopening task..." or "Resolving task...")
		update(desired, function(updated, err)
			if err then
				notify.error(tostring(err))
				on_done(nil, tostring(err))
				return
			end
			local message = is_resolved and "Task reopened" or "Task resolved"
			notify.success(message, { timeout = 1200 })
			if updated then
				upsert_comment(context, updated)
			end
			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

M.toggle_resolved = {
	id = "toggle_resolved",
	label = "Toggle resolved",
	icon = icons.get("success", "actions"),
	---@param context AtlasReviewActionContext
	is_available = function(context)
		if not context.comment or context.comment.deleted then
			return false, "No thread selected"
		end
		local comments = context.provider.capabilities.comments
		return comments ~= nil and comments.set_thread_resolved ~= nil, "Provider does not support resolving threads"
	end,
	---@param context AtlasReviewActionContext
	---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
	---@return boolean handled
	run = function(context, on_done)
		local comment = assert(context.comment)
		local resolved = comment.state ~= "RESOLVED"
		local set_resolved = assert(context.provider.capabilities.comments.set_thread_resolved)
		if context.on_submit then
			context.on_submit()
		end
		notify.loading(resolved and "Resolving thread..." or "Reopening thread...")
		set_resolved(context.pr, comment, resolved, function(ok, err)
			if err or not ok then
				local message = tostring(err or "Unable to update thread")
				notify.error(message)
				on_done(nil, message)
				return
			end
			local message = resolved and "Thread resolved" or "Thread reopened"
			notify.success(message, { timeout = 1200 })
			comment.state = resolved and "RESOLVED" or (comment.outdated and "OUTDATED" or nil)
			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

---@param context AtlasReviewActionContext
---@param capability "submit_review"|"approve"|"request_changes"
---@return boolean, string|nil
local function review_available(context, capability)
	if capability ~= "submit_review" and context.pr.state ~= "open" and context.pr.state ~= "draft" then
		return false, "PR is not open"
	end
	local reviews = context.provider.capabilities.reviews
	return reviews ~= nil and reviews[capability] ~= nil, "Provider does not support this review action"
end

---@param context AtlasReviewActionContext
---@param capability "submit_review"|"approve"|"request_changes"
---@param title string
---@param loading string
---@param success string
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
local function open_review_editor(context, capability, title, loading, success, on_done)
	local submit = assert(context.provider.capabilities.reviews[capability])
	open_editor(context, {
		key = "pr-review",
		title = title,
		on_save = function(body)
			notify.loading(loading)
			submit(context.pr, context.data and context.data.review, body, function(ok, err)
				if not ok then
					local message = vim.trim(title) .. " failed: " .. tostring(err or "Unknown error")
					notify.error(message)
					on_done(nil, err)
					return
				end
				notify.success(success, { timeout = 1200 })
				if capability == "approve" then
					notes.clear(context.pr)
				end
				on_done({ changed_pr = true }, nil)
			end)
		end,
	})
	return true
end

M.start_review = {
	id = "start_review",
	label = "Start review",
	icon = icons.get("review", "actions"),
	is_available = function(context)
		local reviews = context.provider.capabilities.reviews
		return context.data ~= nil
			and not context.data.review.pending
			and reviews ~= nil
			and reviews.start_review ~= nil
	end,
	run = function(context, on_done)
		local data = assert(context.data)
		notify.loading("Starting review...")
		context.provider.capabilities.reviews.start_review(context.pr, data.review, function(ok, err)
			if not ok then
				local message = tostring(err or "Unknown error")
				notify.error("Start review failed: " .. message)
				on_done(nil, message)
				return
			end
			notify.success("Review started", { timeout = 1200 })
			on_done({ changed_pr = true }, nil)
		end)
		return true
	end,
}

M.submit_review = {
	id = "submit_review",
	label = "Submit review",
	icon = icons.get("review", "actions"),
	is_available = function(context)
		return review_available(context, "submit_review")
	end,
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
	icon = icons.get("success", "actions"),
	is_available = function(context)
		return review_available(context, "approve")
	end,
	run = function(context, on_done)
		return open_review_editor(context, "approve", " Approve ", "Approving...", "Approved", on_done)
	end,
}

M.request_changes = {
	id = "request_changes",
	label = "Request changes",
	icon = icons.get("changes", "actions"),
	is_available = function(context)
		return review_available(context, "request_changes")
	end,
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
	icon = icons.get("delete", "actions"),
	confirm = "Discard pending review?",
	is_available = function(context)
		local reviews = context.provider.capabilities.reviews
		return context.data ~= nil and context.data.review.pending and reviews ~= nil and reviews.discard_review ~= nil
	end,
	run = function(context, on_done)
		local data = assert(context.data)
		notify.loading("Discarding review...")
		context.provider.capabilities.reviews.discard_review(context.pr, data.review, function(ok, err)
			if not ok then
				notify.error("Discard review failed: " .. tostring(err or "Unknown error"))
				on_done(nil, err)
				return
			end
			data.review.id = nil
			data.review.commit_hash = nil
			data.review.pending = false
			for _, items in ipairs({ data.comments, data.tasks }) do
				for index = #items, 1, -1 do
					if items[index].pending then
						table.remove(items, index)
					end
				end
			end
			notify.success("Review discarded", { timeout = 1200 })
			on_done({ changed_pr = true }, nil)
		end)
		return true
	end,
}

return M
