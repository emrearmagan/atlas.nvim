local M = {}

local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local core_notify = require("atlas.core.notify")
local events = require("atlas.core.events")
local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.core.keymaps")
local note_popup = require("atlas.pulls.notes.ui.popup")
local notes = require("atlas.pulls.diff.notes")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local hints = require("atlas.pulls.diff.ui.hints")
local statusline = require("atlas.ui.statusline")
local ui_comments = require("atlas.pulls.diff.ui.comments")

local sessions = {}
local review_progress = { "󰝦", "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" }

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
---@field data PullsReviewData

---@class AtlasDiffSource
---@field root string
---@field base_revision string
---@field head_revision string

---@class AtlasDiffReviewPanelSelection
---@field kind "comment"|"note"
---@field comment PullsComment|nil
---@field note AtlasNote|nil

---@class AtlasDiffSessionCallbacks
---@field tabpage integer
---@field close fun(reason: string): boolean|nil
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
---@field statusline AtlasStatusline
---@field review_panel AtlasDiffReviewPanel|nil
---@field review_request { cancel: fun() }|nil
---@field note_target AtlasNoteTarget|nil
---@field viewer_state table
---@field expanded_threads table<string, boolean>
---@field expanded_overlays boolean
---@field help_key string|nil
---@field review_attached boolean
---@field closed boolean
---@field render fun(self: AtlasDiffSession)
---@field notify (fun(level: "loading"|"success"|"warn"|"error"|"info", message: string, duration?: integer))|nil
---@field close (fun(reason: string): boolean|nil)|nil
---@field reopen fun()
---@field focus_item (fun(item: AtlasDiffReviewPanelSelection, focus_diff: boolean))|nil
---@field render_view (fun(output: AtlasDiffRenderOutput))|nil
---@field toggle_review_panel (fun(focus?: boolean))|nil

---@class AtlasDiffRenderOutput
---@field deleted_lines table<integer, [string, string][][]>
---@field deleted_hints table<integer, [string, string][]>
---@field annotated_paths table<string, { comments: boolean, notes: boolean }>

---@param session AtlasDiffSession
---@return AtlasStatuslineSegment[]
local function statusline_items(session)
	local review = session.review
	local pr = review and review.pr
	local review_comments = review and review.data.comments or {}
	local identity = pr and string.format("#%s %s", tostring(pr.id), tostring(pr.title))
		or string.format(
			"%s...%s",
			tostring(session.source.base_revision):sub(1, 8),
			tostring(session.source.head_revision):sub(1, 8)
		)
	local state = session.viewer_state
	local items = {
		{ text = identity, hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
	}
	if state.additions and state.deletions then
		items[#items + 1] = { text = string.format("+%d", state.additions), hl_group = "AtlasFooterSuccess" }
		items[#items + 1] = { text = string.format("-%d", state.deletions), hl_group = "AtlasFooterError" }
	end
	local files = state.files
	if review and type(files) == "table" and #files > 0 then
		local reviewed = 0
		for _, file in ipairs(files) do
			if session.reviewed_files[file.path] then
				reviewed = reviewed + 1
			end
		end
		items[#items + 1] = {
			text = string.format(
				"%s %d / %d reviewed",
				review_progress[math.ceil(reviewed / #files * 8) + 1],
				reviewed,
				#files
			),
			hl_group = reviewed == #files and "AtlasFooterSuccess" or "AtlasFooterInfo",
			align = "right",
			priority = 40,
		}
	end
	if #review_comments > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("comment"), #review_comments),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 30,
		}
	end
	if #session.notes > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("pin"), #session.notes),
			hl_group = "AtlasFooterNote",
			align = "right",
			priority = 20,
		}
	end
	local pending = 0
	for _, comment in ipairs(review_comments) do
		if comment.state == "PENDING" then
			pending = pending + 1
		end
	end
	if pending > 0 or (review and review.data.review.pending) then
		items[#items + 1] = {
			text = icons.pulls_status("inprogress")
				.. " "
				.. (pending > 0 and string.format("%d pending", pending) or "Pending review"),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 50,
		}
	end
	return items
end

---@param opts { viewer_id: string, source: AtlasDiffSource, review: AtlasDiffReview|nil, commits: PullsCommit[]|nil, open_again: fun(on_done: fun(err: string|nil)) }
---@return AtlasDiffSession
function M.new(opts)
	local note_target, note_items = notes.load(opts.review)
	local help_action = opts.viewer_id == "atlas" and "ui.help" or "pulls.external_help"
	local help_key = (keymaps.resolve(help_action) or {})[1]
	---@type AtlasDiffSession
	local session
	session = {
		id = events.new_id(opts.viewer_id),
		viewer_id = opts.viewer_id,
		tabpage = nil,
		source = opts.source,
		review = opts.review,
		notes = note_items,
		reviewed_files = (opts.review and opts.review.context and opts.review.context.reviewed_files) or {},
		current = nil,
		commits = opts.commits or {},
		statusline = statusline.new({ help_key = help_key }),
		review_panel = nil,
		review_request = nil,
		note_target = note_target,
		viewer_state = {},
		expanded_threads = {},
		expanded_overlays = ((config.options.pulls or {}).diff or {}).comment_display == "virtual_lines",
		help_key = help_key,
		review_attached = false,
		closed = false,
		close = nil,
		reopen = function()
			if session.close and session.close("refresh") ~= false then
				vim.schedule(function()
					opts.open_again(function(err)
						if err then
							core_notify.error("Unable to reopen diff: " .. tostring(err), { vim_notify = true })
						end
					end)
				end)
			end
		end,
		notify = function(level, message, duration)
			core_notify.show(level, message, { timeout = duration })
		end,
		render = M.render,
	}
	return session
end

---@param session AtlasDiffSession
---@param callbacks AtlasDiffSessionCallbacks
function M.attach(session, callbacks)
	if session.tabpage and session.tabpage ~= callbacks.tabpage then
		if sessions[session.tabpage] == session then
			sessions[session.tabpage] = nil
		end
	end
	session.tabpage = callbacks.tabpage
	session.close = callbacks.close
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
	review_panel.register_keymaps(panel)
	session.review_panel = panel
	return panel
end

---@param session AtlasDiffSession
---@param current AtlasDiffCurrent
function M.set_current(session, current)
	if session.current then
		ui_comments.clear(session.current)
		notes.clear(session.current)
		hints.clear(session.current)
	end
	session.current = current
	M.render(session)
end

---@param session AtlasDiffSession
function M.render(session)
	if session.closed then
		return
	end
	local output = { deleted_lines = {}, deleted_hints = {}, annotated_paths = comments.annotated_paths(session) }
	if session.current then
		if session.expanded_overlays then
			hints.clear(session.current)
			output.deleted_lines = comments.render(session, session.viewer_state.inline_deleted_lines == true)
			notes.render(session)
		else
			ui_comments.clear(session.current)
			notes.clear(session.current)
			local items, deleted = comments.hints(session, session.viewer_state.inline_deleted_lines == true)
			vim.list_extend(items, notes.hints(session))
			hints.render(session.current, items)
			for line, line_items in pairs(deleted) do
				output.deleted_hints[line] = hints.chunks(line_items)
			end
		end
	end
	review_panel.render(session.review_panel, session)
	if session.current and session.render_view then
		session.render_view(output)
	end
	session.statusline:set_items(statusline_items(session))
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

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	if session.closed then
		return
	end
	session.closed = true
	session.notify = nil
	session.close = nil
	if session.review_request then
		session.review_request.cancel()
		session.review_request = nil
	end
	ui_comments.close_popup(session.id)
	note_popup.close(session.id)
	if session.current then
		ui_comments.clear(session.current)
		notes.clear(session.current)
		hints.clear(session.current)
	end
	review_panel.delete(session.review_panel)
	session.statusline:dispose()
	if session.tabpage and sessions[session.tabpage] == session then
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
