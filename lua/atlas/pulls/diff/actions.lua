local action_runner = require("atlas.core.actions")
local review_actions = require("atlas.pulls.actions.review")
local code_preview = require("atlas.ui.components.code_preview")
local commits = require("atlas.pulls.diff.ui.commits")
local detail_ui = require("atlas.ui.detail")
local icons = require("atlas.ui.shared.icons")
local note_editor = require("atlas.pulls.notes.ui.editor")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local M = {}

---@alias AtlasReviewActionId
---| "add_comment"
---| "add_task"
---| "edit_comment"
---| "edit_review"
---| "delete_comment"
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
---| "toggle_detail_panel"
---| "view_commits"
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

---@class AtlasDiffAction
---@field id AtlasReviewActionId
---@field label string
---@field icon string|nil
---@field is_available (fun(context: AtlasDiffActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasDiffActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil)): boolean|nil

local review_updates = {
	start_review = true,
	submit_review = true,
	discard_review = true,
	approve = true,
	request_changes = true,
}

---@param id AtlasReviewActionId
---@param context AtlasReviewActionContext
---@return AtlasAction|nil
local function shared_action(id, context)
	local registered = context.provider.capabilities.actions
	return registered and registered.find(id) or review_actions[id]
end

---@param selection AtlasDiffSelection
---@return AtlasNoteContext
local function selection_context(selection)
	local first = math.max(1, selection.first - 2)
	local last = math.min(#selection.source_lines, selection.last + 2)
	return { start_line = first, lines = vim.list_slice(selection.source_lines, first, last) }
end

---@param context AtlasDiffActionContext
---@param provider string
---@return { inline?: PullsInlineCommentPosition, file?: PullsFileCommentPosition, pending?: boolean, preview?: AtlasEditorPreview, initial_text?: string, kind?: "suggestion" }|nil, string|nil
local function comment_draft(context, provider)
	if not context.file and not context.selection and context.pending == nil then
		return nil
	end

	local draft = { pending = context.pending }
	local file = context.file
	if file then
		draft.file = { path = file.path, old_path = file.old_path, commit_hash = context.session.data.head_revision }
		return draft
	end

	local selection = context.selection
	if not selection then
		return draft
	end
	if context.suggestion and selection.side ~= "RIGHT" then
		return nil, "Suggestions are only available on the new side of the diff"
	end

	local preview = selection_context(selection)
	draft.inline = selection.inline
	draft.preview = code_preview.render({
		file_path = selection.file.path,
		lines = preview.lines,
		start_line = preview.start_line,
		anchor_start = selection.first,
		anchor_line = selection.last,
	})

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
	local result = context.session.data
	local review = result.review
	local pr = result.pr
	if not pr or not review or not review.data then
		notify.warn("Review data is unavailable")
		return nil
	end

	local provider = providers.load(pr.provider, "pulls")
	if not provider then
		notify.warn("Pull request provider is unavailable")
		return nil
	end
	---@cast provider PullsProvider

	local draft, err = comment_draft(context, pr.provider)
	if err then
		notify.info(err)
		return nil
	end

	return {
		provider = provider,
		pr = pr,
		current_user = result.current_user,
		data = review.data,
		comment = context.comment,
		review_entry = context.review_entry,
		draft = draft,
		review_context = review.context,
		on_submit = context.on_submit,
	}
end

---@param items AtlasNote[]
---@param note AtlasNote
local function replace_note(items, note)
	for index, existing in ipairs(items) do
		if existing.id == note.id then
			items[index] = note
			return
		end
	end
end

---@type AtlasDiffAction
M.add_note = {
	id = "add_note",
	label = "Add note",
	icon = icons.general("pin"),
	run = function(context, on_done)
		local data = context.session.data.notes
		if not data then
			notify.warn("Notes are unavailable")
			return false
		end

		local selection = context.selection
		if not selection then
			return false
		end
		if selection.side ~= "RIGHT" then
			notify.info("Notes are only available on the new side of the diff")
			return false
		end

		note_editor.create(data.target, {
			file_path = selection.file.path,
			line = selection.last,
			body = "",
			context = selection_context(selection),
		}, function(note, err)
			if not note then
				notify.error(err)
				return
			end

			data.items[#data.items + 1] = note
			notify.success("Note added", { timeout = 1200 })
			on_done({ changed_pr = false, message = "Note added" }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.edit_note = {
	id = "edit_note",
	label = "Edit note",
	icon = icons.action("edit"),
	run = function(context, on_done)
		local data = context.session.data.notes
		local note = context.note
		if not data or not note then
			return false
		end

		note_editor.edit(data.target, note, function(updated, err)
			if context.on_submit then
				context.on_submit()
			end
			if not updated then
				notify.error(err)
				return
			end

			replace_note(data.items, updated)
			notify.success("Note updated", { timeout = 1200 })
			on_done({ changed_pr = false, message = "Note updated" }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.delete_note = {
	id = "delete_note",
	label = "Delete note",
	icon = icons.action("delete"),
	run = function(context, on_done)
		local data = context.session.data.notes
		local note = context.note
		if not data or not note then
			return false
		end

		vim.ui.input({ prompt = "Delete note? [y/N]: " }, function(answer)
			answer = answer and vim.trim(answer):lower()
			if answer ~= "y" and answer ~= "yes" then
				return
			end

			if context.on_submit then
				context.on_submit()
			end
			local deleted, err = notes.delete(data.target, note.id)
			if not deleted then
				notify.error(err)
				return
			end

			for index, existing in ipairs(data.items) do
				if existing.id == note.id then
					table.remove(data.items, index)
					break
				end
			end

			notify.success("Note deleted", { timeout = 1200 })
			on_done({ changed_pr = false, message = "Note deleted" }, nil)
		end)
		return true
	end,
}

---@type AtlasDiffAction
M.toggle_note_resolved = {
	id = "toggle_note_resolved",
	label = "Toggle note resolved",
	icon = icons.action("success"),
	run = function(context, on_done)
		local data = context.session.data.notes
		local note = context.note
		if not data or not note then
			return false
		end

		local resolved = not note.resolved
		local updated, err = notes.update(data.target, note.id, { resolved = resolved })
		if context.on_submit then
			context.on_submit()
		end
		if not updated then
			notify.error(err)
			return false
		end

		replace_note(data.items, updated)
		local message = resolved and "Note resolved" or "Note reopened"
		notify.success(message, { timeout = 1200 })
		on_done({ changed_pr = false, message = message }, nil)
		return true
	end,
}

---@param session AtlasDiffSession
---@param on_done fun(ok: boolean)
local function reload_review(session, on_done)
	local success = true
	local note_data = session.data.notes
	if note_data then
		local items, err = notes.list(note_data.target)
		if items then
			note_data.items = items
		else
			success = false
			notify.error(err)
		end
	end

	local pr = session.data.pr
	local provider = pr and providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider|nil
	local reviews = provider and provider.capabilities.reviews
	if not pr or not reviews then
		on_done(success)
		return
	end

	if session.requests.review then
		session.requests.review.cancel()
	end
	local requests = request_scope.new()
	session.requests.review = requests
	local starts = {
		review = function(done)
			return reviews.fetch(pr, { force_refresh = true }, done)
		end,
	}
	if reviews.fetch_review_context then
		starts.context = function(done)
			return reviews.fetch_review_context(pr, { force_refresh = true }, done)
		end
	end

	requests.all(starts, function(values, errors)
		session.requests.review = nil
		if values.review or values.context then
			local review = session.data.review or {}
			if values.review then
				review.data = review.data or {}
				for key, value in pairs(values.review) do
					review.data[key] = value
				end
			end
			if values.context then
				review.context = values.context
				if values.context.reviewed_files then
					session.reviewed_files = vim.deepcopy(values.context.reviewed_files)
				end
			end
			session.data.review = review
		end
		for _, err in pairs(errors) do
			success = false
			notify.error("Unable to refresh review\n\n" .. err)
		end
		on_done(success)
	end)
end

---@type AtlasDiffAction
M.refresh_review = {
	id = "refresh_review",
	label = "Refresh review",
	icon = icons.action("retry"),
	run = function(context, on_done)
		notify.loading("Refreshing review...")
		reload_review(context.session, function(ok)
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
	icon = icons.action("details"),
	run = function(context, on_done)
		local session = context.session
		local pr = session.data.pr
		if not pr then
			return false
		end

		if detail_ui.is_showing("pulls", session.view.tabpage) then
			detail_ui.close(session.view.tabpage)
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
				session.data.pr = updated_pr
				reload_review(session, function()
					on_done(result, nil)
				end)
			end,
		})
		return true
	end,
}

---@type AtlasDiffAction
M.open_in_browser = {
	id = "open_in_browser",
	label = "Open in browser",
	icon = icons.action("open_in_browser"),
	run = function(context)
		local session = context.session
		local pr = session.data.pr
		if not pr then
			return false
		end

		local by_line = session.view.annotations[vim.api.nvim_get_current_buf()]
		local items = by_line and by_line[vim.api.nvim_win_get_cursor(0)[1]]
		for _, item in ipairs(items or {}) do
			local comment = item.thread and item.thread.comment
			local url = comment and (comment.html_url or comment.url)
			if url and url ~= "" then
				vim.ui.open(url)
				return true
			end
		end

		vim.ui.open(pr.link.html)
		return true
	end,
}

---@type AtlasDiffAction
M.view_commits = {
	id = "view_commits",
	label = "View commits",
	icon = icons.pulls("commit"),
	is_available = function(context)
		return #context.session.data.commits > 0, "No commits available"
	end,
	run = function(context)
		local result = context.session.data
		picker.select_with_preview({
			title = "Commits",
			items = result.commits,
			key = function(commit)
				return commit.hash
			end,
			format_item = function(commit)
				local hash = (commit.short_hash or commit.hash):sub(1, 8)
				local message = " " .. commit.message:match("^[^\r\n]*")
				return hash .. message, { { hash, "AtlasTextMuted" }, { message, "Normal" } }
			end,
			preview_item = function(commit, done)
				done(commits.preview(commit))
			end,
			on_select = function(commit)
				if not commit then
					return
				end

				-- Opening a diff imports these actions, so load it when a commit is picked.
				require("atlas.pulls.diff").open_commit({ commit = commit.hash, root = result.root })
			end,
		})
		return true
	end,
}

---@type AtlasDiffAction
M.open_actions = {
	id = "open_actions",
	label = "Review actions",
	icon = icons.action("review"),
	run = function(context, on_done)
		local review = review_context(context)
		if not review then
			return false
		end

		local reviews = review.provider.capabilities.reviews or {}
		---@type AtlasAction[]
		local items = {}

		---@param id AtlasReviewActionId
		local function add(id)
			local action = shared_action(id, review)
			if reviews[id] and action_runner.is_available(action, review) then
				items[#items + 1] = action
			end
		end

		local pending = review.data.review.pending
		local reviewable = review.pr.state == "open" or review.pr.state == "draft"
		if reviewable then
			add(pending and "submit_review" or "start_review")
		end
		if pending then
			add("discard_review")
		end
		if reviewable then
			add("approve")
			add("request_changes")
		end

		items[#items + 1] = M.toggle_detail_panel
		if action_runner.is_available(M.view_commits, context) then
			items[#items + 1] = M.view_commits
		end

		picker.select({
			title = "Review action",
			items = items,
			format_item = icons.format_action,
			on_select = function(action)
				if action then
					M.dispatch(action.id, context, on_done)
				end
			end,
		})
		return true
	end,
}

---@param callback fun(context: AtlasPullActionContext, done: fun(result: PullsActionResult|nil, err: string|nil)): any
---@param context AtlasDiffActionContext
---@param on_done fun(result: PullsActionResult, err: string|nil)
---@return any
function M.run_custom(callback, context, on_done)
	local shared = review_context(context)
	if not shared then
		return
	end

	local session = context.session
	shared.buf = vim.api.nvim_get_current_buf()
	return callback(shared, function(result, err)
		if not result or err or session.closed then
			return
		end

		if result.changed_pr then
			reload_review(session, function()
				on_done(result, nil)
			end)
			return
		end
		on_done(result, nil)
	end)
end

---@param id AtlasReviewActionId
---@param context AtlasDiffActionContext
---@param on_done (fun(result: PullsActionResult|nil, err: string|nil))|nil
---@return boolean handled
function M.dispatch(id, context, on_done)
	local session = context.session
	local function complete(result, err)
		if not result or err or session.closed then
			return
		end
		if on_done then
			on_done(result, nil)
		end
	end

	local action = M[id]
	if action then
		return action_runner.run(action, context, complete)
	end

	local shared = review_context(context)
	if not shared then
		return false
	end

	return action_runner.run(shared_action(id, shared), shared, function(result, err)
		if result and not err and not session.closed and review_updates[id] then
			reload_review(session, function()
				complete(result, nil)
			end)
			return
		end
		complete(result, err)
	end)
end

return M
