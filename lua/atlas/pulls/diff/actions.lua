local action_runner = require("atlas.core.actions")
local review_actions = require("atlas.pulls.actions.review")
local code_preview = require("atlas.ui.components.code_preview")
local detail_window = require("atlas.pulls.ui.detail.window")
local diff = require("atlas.core.git.diff")
local icons = require("atlas.ui.shared.icons")
local note_editor = require("atlas.pulls.notes.ui.editor")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local reactions = require("atlas.ui.shared.reactions")
local request_scope = require("atlas.core.requests")

local M = {}

---@alias AtlasReviewActionId
---| "add_comment"
---| "add_task"
---| "edit_comment"
---| "edit_review"
---| "delete_comment"
---| "react"
---| "toggle_task"
---| "toggle_resolved"
---| "start_review"
---| "submit_review"
---| "discard_review"
---| "approve"
---| "request_changes"
---| "add_note"
---| "edit_note"
---| "delete_note"
---| "toggle_note_resolved"
---| "note_to_comment"
---| "toggle_detail_panel"
---| "toggle_review_panel"
---| "toggle_commits"
---| "open_in_browser"
---| "open_actions"
---| "refresh_review"

---@class AtlasDiffActionContext
---@field session AtlasDiffSession
---@field comment PullsComment|nil
---@field review_entry PullsReviewHistoryEntry|nil
---@field note AtlasNote|nil
---@field selection AtlasDiffSelection|nil
---@field file AtlasDiffFile|nil
---@field pending boolean|nil
---@field suggestion boolean|nil
---@field on_submit (fun())|nil
---@field viewer AtlasDiffViewer|nil

---@class AtlasDiffAction: AtlasAction
---@field id AtlasReviewActionId
---@field is_available (fun(context: AtlasDiffActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasDiffActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil)): boolean|nil

---@param context AtlasDiffActionContext
---@return boolean, string|nil
local function is_pr(context)
	return context.session.source.kind == "pr", "Not a pull request"
end

---@param context AtlasDiffActionContext
---@return boolean, string|nil
local function has_note(context)
	return context.session.notes ~= nil and context.note ~= nil, "No note selected"
end

---@param id AtlasReviewActionId
---@param context AtlasReviewActionContext
---@return AtlasAction|nil
local function shared_action(id, context)
	return action_runner.find(context.provider.capabilities.actions, id) or review_actions[id]
end

---@param selection AtlasDiffSelection
---@return { start_line: integer, lines: string[] }
local function selection_context(selection)
	local first = math.max(1, selection.first - 2)
	local last = math.min(#selection.source_lines, selection.last + 2)
	return { start_line = first, lines = vim.list_slice(selection.source_lines, first, last) }
end

---@param selection AtlasDiffSelection
---@return AtlasEditorPreview
local function selection_preview(selection)
	local context = selection_context(selection)
	return code_preview.render({
		file_path = selection.file.path,
		lines = context.lines,
		start_line = context.start_line,
		anchor_start = selection.first,
		anchor_line = selection.last,
	})
end

---@param context AtlasDiffActionContext
---@param provider string
---@return { inline?: PullsInlineCommentPosition, file?: PullsFileCommentPosition, pending?: boolean, preview?: AtlasEditorPreview, initial_text?: string, kind?: "suggestion" }
local function comment_draft(context, provider)
	local draft = { pending = context.pending }
	local file = context.file
	if file then
		-- TODO: In commit views this is the commit's old_path. A file renamed there but added in the PR sends a
		-- path the PR doesn't know, so providers may reject it. Line comments already handle this in selection().
		draft.file =
			{ path = file.path, old_path = file.old_path, commit_hash = context.session.full_range.head_revision }
		return draft
	end

	local selection = context.selection
	if not selection then
		return draft
	end

	draft.inline = selection.inline
	draft.preview = selection_preview(selection)

	if context.suggestion then
		local lines = vim.list_slice(selection.source_lines, selection.first, selection.last)
		local fence = "suggestion"
		if provider == "gitlab" then
			fence = string.format("suggestion:-%d+0", #lines - 1)
		end
		draft.initial_text = string.format("\n```%s\n%s\n```", fence, table.concat(lines, "\n"))
		draft.kind = "suggestion"
	end

	return draft
end

---@param context AtlasDiffActionContext
---@return AtlasReviewActionContext|nil
local function review_context(context)
	local session = context.session
	local data = session.review
	local pr = session.source.pr
	if not pr or not data then
		notify.warn("Review data is unavailable")
		return nil
	end

	local provider = providers.load(pr.provider, "pulls")
	if not provider then
		notify.warn("Pull request provider is unavailable")
		return nil
	end
	---@cast provider PullsProvider

	return {
		provider = provider,
		pr = pr,
		current_user = session.current_user,
		data = data,
		comment = context.comment,
		review_entry = context.review_entry,
		on_submit = context.on_submit,
	}
end

---@type AtlasDiffAction
M.add_comment = {
	id = "add_comment",
	label = "Add comment",
	icon = icons.get("comment"),
	is_available = function(context)
		local selection = context.selection
		if context.suggestion and selection and selection.side ~= "RIGHT" then
			return false, "Suggestions are only available on the new side of the diff"
		end
		return true
	end,
	run = function(context, on_done)
		local shared = review_context(context)
		if not shared then
			return false
		end

		shared.draft = comment_draft(context, shared.pr.provider)
		return action_runner.run(shared_action("add_comment", shared), shared, on_done)
	end,
}

---@type AtlasDiffAction
M.add_note = {
	id = "add_note",
	label = "Add note",
	icon = icons.get("pin"),
	is_available = function(context)
		if not context.session.notes then
			return false, "Notes are unavailable"
		end
		local selection = context.selection
		return selection ~= nil and selection.side == "RIGHT" and selection.inline.to ~= nil,
			"Notes are only available on the new side of the diff"
	end,
	run = function(context, on_done)
		local session = context.session
		local data = assert(session.notes)
		local selection = assert(context.selection)
		local last = assert(selection.inline.to)
		local start_line = selection.inline.start_to or last
		local note_context = selection_context(selection)
		note_context.start_line = note_context.start_line + start_line - selection.first
		note_editor.create(data.target, {
			file_path = selection.file.path,
			commit = session.full_range.head_revision,
			start_line = start_line,
			end_line = last,
			body = "",
			context = note_context,
		}, function(note, err)
			if not note then
				notify.error(err)
				return
			end

			session:put_note(note)
			notify.success("Note added", { timeout = 1200 })
			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.note_to_comment = {
	id = "note_to_comment",
	label = "Comment from note",
	icon = icons.get("comment"),
	is_available = function(context)
		local available, reason = has_note(context)
		if not available then
			return false, reason
		end
		return not context.session.notes.positions[context.note.id].outdated, "Note is outdated, edit or delete it"
	end,
	run = function(context, on_done)
		local shared = review_context(context)
		if not shared then
			return false
		end

		local session = context.session
		local data = assert(session.notes)
		local note = assert(context.note)
		local position = data.positions[note.id]

		-- TODO: In commit views session.files are the shown commits files, not the PRs. So a file added in the PR
		-- but only modified in the commit would probably fail here. Should reuse the normal comment selection instead.
		local file = vim.iter(session.files):find(function(item)
			return item.path == note.file_path or item.old_path == note.file_path
		end)
		if not file then
			notify.info("File is not in this diff")
			return false
		end

		request_scope.new().all({
			old = function(done)
				if file.status == "added" then
					done("")
					return nil
				end
				return diff.read(
					session.full_range.root,
					session.full_range.base_revision,
					file.old_path or file.path,
					done
				)
			end,
			new = function(done)
				return diff.read(session.full_range.root, session.full_range.head_revision, file.path, done)
			end,
		}, function(contents, errors)
			local err = errors.old or errors.new
			if err then
				notify.error(err)
				return
			end
			if session.closed then
				return
			end

			local hunks = diff.compute(contents.old, contents.new)
			local function old_line(line)
				if file.status == "added" then
					return nil
				end
				local opposite, hunk = diff.map_line(hunks, "RIGHT", line)
				return not hunk and opposite or nil
			end

			local first, last = position.start_line, position.end_line
			---@type AtlasDiffSelection
			local selection = {
				file = file,
				side = "RIGHT",
				first = first,
				last = last,
				source_lines = vim.split(contents.new, "\n", { plain = true }),
				inline = {
					path = file.path,
					old_path = file.old_path,
					from = old_line(last),
					to = last,
					start_from = first ~= last and old_line(first) or nil,
					start_to = first ~= last and first or nil,
					commit_hash = session.full_range.head_revision,
				},
			}
			shared.draft = {
				inline = selection.inline,
				preview = selection_preview(selection),
				pending = context.pending,
				initial_text = note.body,
			}

			action_runner.run(shared_action("add_comment", shared), shared, function(comment, comment_err)
				if not comment or comment_err or session.closed then
					return
				end

				local deleted, delete_err = notes.delete(data.target, note.id)
				if not deleted then
					notify.error(delete_err)
				else
					session:remove_note(note)
				end
				on_done(comment, nil)
			end)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.edit_note = {
	id = "edit_note",
	label = "Edit note",
	icon = icons.get("edit", "actions"),
	is_available = has_note,
	run = function(context, on_done)
		local data = assert(context.session.notes)
		local note = assert(context.note)
		note_editor.edit(data.target, note, function(updated, err)
			if context.on_submit then
				context.on_submit()
			end
			if not updated then
				notify.error(err)
				return
			end

			context.session:put_note(updated)
			notify.success("Note updated", { timeout = 1200 })
			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.delete_note = {
	id = "delete_note",
	label = "Delete note",
	icon = icons.get("delete", "actions"),
	confirm = "Delete note?",
	is_available = has_note,
	run = function(context, on_done)
		local data = assert(context.session.notes)
		local note = assert(context.note)
		if context.on_submit then
			context.on_submit()
		end
		local deleted, err = notes.delete(data.target, note.id)
		if not deleted then
			notify.error(err)
			return
		end

		context.session:remove_note(note)
		notify.success("Note deleted", { timeout = 1200 })
		on_done({ changed_pr = false }, nil)
		return true
	end,
}

---@type AtlasDiffAction
M.toggle_note_resolved = {
	id = "toggle_note_resolved",
	label = "Toggle note resolved",
	icon = icons.get("success", "actions"),
	is_available = has_note,
	run = function(context, on_done)
		local data = assert(context.session.notes)
		local note = assert(context.note)
		local resolved = not note.resolved
		local updated, err = notes.update(data.target, note.id, { resolved = resolved })
		if context.on_submit then
			context.on_submit()
		end
		if not updated then
			notify.error(err)
			return
		end

		context.session:put_note(updated)
		local message = resolved and "Note resolved" or "Note reopened"
		notify.success(message, { timeout = 1200 })
		on_done({ changed_pr = false }, nil)
		return true
	end,
}

---@param context AtlasDiffActionContext
---@return AtlasReactionsCapability|nil
local function reactions_capability(context)
	local pr = context.session.source.pr
	local provider = pr and providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider|nil
	local comments = provider and provider.capabilities.comments
	return comments and comments.reactions
end

---@type AtlasDiffAction
M.react = {
	id = "react",
	label = "Add reaction",
	is_available = function(context)
		if not reactions_capability(context) then
			return false, "Reactions are unavailable"
		end
		local comment = context.comment
		return comment ~= nil and not comment.deleted and not comment.is_task, "Select a comment"
	end,
	run = function(context, on_done)
		local session = context.session
		local capability = assert(reactions_capability(context))
		reactions.pick(capability, assert(session.source.pr), assert(context.comment), function()
			return not session.closed
		end, function()
			if context.on_submit then
				context.on_submit()
			end

			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.refresh_review = {
	id = "refresh_review",
	label = "Refresh review",
	icon = icons.get("retry", "actions"),
	run = function(context, on_done)
		notify.loading("Refreshing review...")
		context.session:reload(function(ok)
			if ok then
				notify.success("Review refreshed", { timeout = 1200 })
			end
			on_done({ changed_pr = false }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.toggle_detail_panel = {
	id = "toggle_detail_panel",
	label = "Show details",
	icon = icons.get("details", "actions"),
	is_available = is_pr,
	run = function(context, on_done)
		local session = context.session
		local source = session.source
		local pr = assert(source.pr)

		local tabpage = vim.api.nvim_get_current_tabpage()
		if detail_window.is_open(tabpage) then
			detail_window.close(tabpage)
			return true
		end

		-- PR details imports diff through its actions, so load it when needed.
		local detail = require("atlas.pulls.ui.detail")
		detail.open(pr, {
			on_update = function(updated_pr, result)
				if session.closed then
					return
				end

				detail.refresh(updated_pr)
				source.pr = updated_pr
				on_done(result, nil)
			end,
		})
		return true
	end,
}

---@type AtlasDiffAction
M.toggle_review_panel = {
	id = "toggle_review_panel",
	label = "Show review panel",
	icon = icons.get("comment"),
	run = function(context)
		local viewer = context.viewer
		---@cast viewer -nil
		viewer:toggle_review_panel()
		return true
	end,
}

---@type AtlasDiffAction
M.toggle_commits = {
	id = "toggle_commits",
	label = "Show commits",
	icon = icons.get("commit"),
	is_available = function(context)
		return #context.session.commits > 0, "No commits available"
	end,
	run = function(context)
		local viewer = context.viewer
		---@cast viewer -nil
		viewer:toggle_commits()
		return true
	end,
}

---@type AtlasDiffAction
M.open_in_browser = {
	id = "open_in_browser",
	label = "Open in browser",
	icon = icons.get("open_in_browser", "actions"),
	is_available = is_pr,
	run = function(context)
		local pr = assert(context.session.source.pr)
		vim.ui.open(context.comment and context.comment.url or pr.link.html)
		return true
	end,
}

---@type AtlasDiffAction
M.open_actions = {
	id = "open_actions",
	label = "Review actions",
	icon = icons.get("review", "actions"),
	run = function(context, on_done)
		local review = review_context(context)
		if not review then
			return false
		end

		---@type AtlasAction[]
		local items = {}

		---@param id AtlasReviewActionId
		local function add(id)
			local action = shared_action(id, review)
			if action_runner.is_available(action, review) then
				items[#items + 1] = action
			end
		end

		if review.pr.state == "open" or review.pr.state == "draft" then
			add(review.data.review.pending and "submit_review" or "start_review")
		end
		add("discard_review")
		add("approve")
		add("request_changes")

		items[#items + 1] = M.toggle_detail_panel
		items[#items + 1] = M.toggle_review_panel
		if action_runner.is_available(M.toggle_commits, context) then
			items[#items + 1] = M.toggle_commits
		end
		items[#items + 1] = M.refresh_review
		items[#items + 1] = M.open_in_browser

		action_runner.select("Review action", items, function(action)
			M.dispatch(action.id, context, on_done)
		end)
		return true
	end,
}

---@param session AtlasDiffSession
---@param on_done fun(result: PullsActionResult, err: string|nil)
---@param result PullsActionResult|nil
---@param err string|nil
local function finish(session, on_done, result, err)
	if not result or err or session.closed then
		return
	end
	if not result.changed_pr then
		on_done(result, nil)
		return
	end
	session:reload(function()
		on_done(result, nil)
	end)
end

---@param callback fun(context: AtlasPullActionContext, done: fun(result: PullsActionResult|nil, err: string|nil)): any
---@param context AtlasDiffActionContext
---@param on_done fun(result: PullsActionResult, err: string|nil)
---@return any
function M.run_custom(callback, context, on_done)
	local shared = review_context(context)
	if not shared then
		return
	end

	shared.buf = vim.api.nvim_get_current_buf()
	return callback(shared, function(result, err)
		finish(context.session, on_done, result, err)
	end)
end

---@param id AtlasReviewActionId
---@param context AtlasDiffActionContext
---@param on_done fun(result: PullsActionResult, err: string|nil)
---@return boolean handled
function M.dispatch(id, context, on_done)
	local function complete(result, err)
		finish(context.session, on_done, result, err)
	end

	local action = M[id]
	if action then
		return action_runner.run(action, context, complete)
	end

	local shared = review_context(context)
	if not shared then
		return false
	end
	return action_runner.run(shared_action(id, shared), shared, complete)
end

return M
