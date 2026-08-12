local M = {}

local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local events = require("atlas.core.events")
local keymaps = require("atlas.core.keymaps")
local note_popup = require("atlas.pulls.notes.ui.popup")
local notes = require("atlas.pulls.diff.notes")
local review = require("atlas.pulls.diff.review")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local statusline = require("atlas.pulls.diff.ui.statusline")
local ui_comments = require("atlas.pulls.diff.ui.comments")

local sessions = {}

---@alias AtlasDiffLayout "side-by-side"|"inline"

---@class AtlasDiffWindow
---@field buf integer
---@field win integer|nil

---@class AtlasDiffLineChange
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class AtlasDiffDocument
---@field status DiffFileStatus
---@field old { path: string, lines: string[] }
---@field new { path: string, lines: string[] }
---@field changes AtlasDiffLineChange[]
---@field binary boolean

---@class AtlasDiffCurrent
---@field layout AtlasDiffLayout
---@field document AtlasDiffDocument
---@field left AtlasDiffWindow
---@field right AtlasDiffWindow

---@class AtlasDiffReview
---@field provider PullsProvider
---@field pr PullRequest
---@field current_user PullsUser|nil
---@field context PullsReviewContext|nil
---@field state PullsReview
---@field comments PullsComment[]
---@field tasks PullsComment[]

---@class AtlasDiffSource
---@field root string
---@field base_revision string
---@field head_revision string|nil Nil means the working tree.

---@class AtlasDiffReviewPanelSelection
---@field kind "comment"|"note"
---@field comment PullsComment|nil
---@field note AtlasNote|nil

---@class AtlasDiffSessionCallbacks
---@field tabpage integer
---@field notify fun(level: "loading"|"success"|"warn"|"error"|"info", message: string, duration?: integer)
---@field focus_item fun(item: AtlasDiffReviewPanelSelection, focus_diff: boolean)
---@field render_view fun(output: AtlasDiffRenderOutput)
---@field toggle_review_panel fun(focus?: boolean)

---@class AtlasDiffSession
---@field id string
---@field viewer_id string
---@field tabpage integer|nil
---@field source AtlasDiffSource
---@field review AtlasDiffReview|nil
---@field notes AtlasNote[]
---@field reviewed_files table<string, boolean>
---@field current AtlasDiffCurrent|nil
---@field commits PullsCommit[]
---@field statusline AtlasDiffStatuslineState
---@field review_panel AtlasDiffReviewPanel|nil
---@field review_request { cancel: fun() }|nil
---@field review_action_requests { cancel: fun() }[]
---@field review_generation integer
---@field note_target AtlasNoteTarget|nil
---@field viewer_state table
---@field expanded_threads table<string, boolean>
---@field show_comments boolean
---@field help_key string
---@field review_attached boolean
---@field closed boolean
---@field render fun(self: AtlasDiffSession)
---@field notify (fun(level: "loading"|"success"|"warn"|"error"|"info", message: string, duration?: integer))|nil
---@field reload (fun(target?: AtlasLoadingTarget))|nil
---@field focus_item (fun(item: AtlasDiffReviewPanelSelection, focus_diff: boolean))|nil
---@field render_view (fun(output: AtlasDiffRenderOutput))|nil
---@field toggle_review_panel (fun(focus?: boolean))|nil

---@class AtlasDiffRenderOutput
---@field deleted_lines table<integer, [string, string][][]>
---@field annotated_paths table<string, { comments: boolean, notes: boolean }>

---@param opts { viewer_id: string, source: AtlasDiffSource, review: AtlasDiffReview|nil, commits: PullsCommit[]|nil }
---@return AtlasDiffSession
function M.new(opts)
	local note_target, note_items = notes.load(opts.review)
	local session = {
		id = events.new_id(opts.viewer_id),
		viewer_id = opts.viewer_id,
		tabpage = nil,
		source = opts.source,
		review = opts.review,
		notes = note_items,
		reviewed_files = (opts.review and opts.review.context and opts.review.context.reviewed_files) or {},
		current = nil,
		commits = opts.commits or {},
		statusline = statusline.new(),
		review_panel = nil,
		review_request = nil,
		review_action_requests = {},
		review_generation = 0,
		note_target = note_target,
		viewer_state = {},
		expanded_threads = {},
		show_comments = ((config.options.pulls or {}).diff or {}).show_comments ~= false,
		help_key = opts.viewer_id == "atlas" and (keymaps.resolve("ui.help") or { "g?" })[1] or "gA",
		review_attached = false,
		closed = false,
		render = M.render,
	}
	return session
end

---@param session AtlasDiffSession
---@param callbacks AtlasDiffSessionCallbacks
function M.attach(session, callbacks)
	if session.tabpage and session.tabpage ~= callbacks.tabpage then
		sessions[session.tabpage] = nil
	end
	session.tabpage = callbacks.tabpage
	session.notify = callbacks.notify
	session.focus_item = callbacks.focus_item
	session.render_view = callbacks.render_view
	session.toggle_review_panel = callbacks.toggle_review_panel
	sessions[callbacks.tabpage] = session
end

---@param session AtlasDiffSession
---@param name string
---@return AtlasDiffReviewPanel
function M.create_review_panel(session, name)
	local panel = review_panel.create(name, session)
	session.review_panel = panel
	return panel
end

---@param session AtlasDiffSession
---@param current AtlasDiffCurrent
function M.set_current(session, current)
	if session.current then
		ui_comments.clear(session.current)
		notes.clear(session.current)
	end
	session.current = current
	M.render(session)
end

---@param session AtlasDiffSession
function M.render(session)
	if session.closed then
		return
	end
	local output = { deleted_lines = {}, annotated_paths = comments.annotated_paths(session) }
	if session.current then
		if session.show_comments then
			output.deleted_lines = comments.render(session, session.viewer_state.inline_deleted_lines == true)
		else
			ui_comments.clear(session.current)
		end
		notes.render(session)
	end
	review_panel.render(session.review_panel, session)
	if session.current and session.render_view then
		session.render_view(output)
	end
	vim.cmd("redrawstatus")
end

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
function M.notify(session, level, message, duration)
	if session.notify then
		session.notify(level, message, duration)
	end
end

---@param session AtlasDiffSession
function M.review_attached(session)
	if not session.review or session.review_attached then
		return
	end
	session.review_attached = true
	events.emit("AtlasReviewAttached", {
		session_id = session.id,
		viewer = session.viewer_id,
		tabpage = session.tabpage,
		root = session.source.root,
		base_revision = session.source.base_revision,
		head_revision = session.source.head_revision,
	})
end

---@param tabpage integer|nil
---@return AtlasDiffSession|nil
function M.get(tabpage)
	return sessions[tabpage or vim.api.nvim_get_current_tabpage()]
end

---@return AtlasDiffSession[]
function M.all()
	local result = {}
	for _, session in pairs(sessions) do
		table.insert(result, session)
	end
	return result
end

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	if session.closed then
		return
	end
	session.closed = true
	if session.review_request then
		session.review_request.cancel()
		session.review_request = nil
	end
	review.cancel_actions(session)
	ui_comments.close_popup(session.id)
	note_popup.close()
	if session.current then
		ui_comments.clear(session.current)
		notes.clear(session.current)
	end
	review_panel.delete(session.review_panel)
	statusline.dispose(session.statusline)
	if session.tabpage then
		sessions[session.tabpage] = nil
	end
	if session.review_attached then
		session.review_attached = false
		events.emit("AtlasReviewDetached", {
			session_id = session.id,
			viewer = session.viewer_id,
			tabpage = session.tabpage,
			root = session.source.root,
			base_revision = session.source.base_revision,
			head_revision = session.source.head_revision,
			reason = reason or "viewer_closed",
		})
	end
end

return M
