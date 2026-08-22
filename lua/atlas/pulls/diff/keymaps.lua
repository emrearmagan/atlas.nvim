local M = {}

local actions = require("atlas.pulls.diff.actions")
local comments = require("atlas.pulls.diff.comments")
local help = require("atlas.ui.popups.help")
local notes = require("atlas.pulls.diff.notes")
local picker = require("atlas.picker")
local pull_actions = require("atlas.pulls.actions")
local resolver = require("atlas.core.keymaps")
local review = require("atlas.pulls.diff.review")
local session_api = require("atlas.pulls.diff.session")

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param callback fun()
---@param mode string|string[]|nil
local function add(items, action, desc, callback, mode)
	local keys = resolver.resolve(action)
	if keys then
		items[#items + 1] = {
			key = keys,
			desc = desc,
			callback = callback,
			mode = mode,
			opts = { nowait = true, silent = true },
		}
	end
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
local function content_buffer(session, buf)
	local current = session.current
	return current ~= nil and (buf == current.left.buf or buf == current.right.buf)
end

---@param session AtlasDiffSession
---@param buf integer
---@param on_comment fun()
---@param on_note fun()
local function with_item(session, buf, on_comment, on_note)
	local has_comment = comments.has_at_cursor(session, buf)
	local has_note = notes.has_at_cursor(session, buf)
	if has_comment and has_note then
		picker.select({
			title = "Select review item",
			items = { "Comment thread", "Local notes" },
			on_select = function(choice)
				if choice == "Comment thread" then
					on_comment()
				elseif choice == "Local notes" then
					on_note()
				end
			end,
		})
	elseif has_comment then
		on_comment()
	elseif has_note then
		on_note()
	end
end

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param callback fun(start_line?: integer, end_line?: integer)
local function add_range(items, action, desc, callback)
	add(items, action, desc, function()
		if vim.fn.mode() == "n" then
			callback()
			return
		end
		local start_line = vim.fn.line("v")
		local end_line = vim.api.nvim_win_get_cursor(0)[1]
		vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
		callback(start_line, end_line)
	end, { "n", "x" })
end

---@param session AtlasDiffSession
---@param opts { buffers: integer[], reload: fun()|nil, help_key: string|string[]|nil, file_buffers: integer[]|nil, add_file_comment: (fun(pending: boolean))|nil }
function M.register(session, opts)
	local action_context = session.review and review.action_context(session) or nil
	local reviews = session.review and session.review.provider.capabilities.reviews or {}
	local reviewable = session.review and (session.review.pr.state == "open" or session.review.pr.state == "draft")
	local pending = session.review and session.review.data.review.pending == true
	local can_complete = reviewable and (not pending or reviews.submit_review ~= nil)
	local has_review_items = session.review ~= nil or session.note_target ~= nil
	local file_buffers = {}
	for _, buf in ipairs(opts.file_buffers or {}) do
		file_buffers[buf] = true
	end
	for _, buf in ipairs(opts.buffers) do
		if vim.api.nvim_buf_is_valid(buf) then
			local items = {}
			if has_review_items then
				add(items, "ui.refresh", "Refresh review", function()
					if session.review then
						review.reload(session)
					end
					if session.note_target then
						notes.reload(session)
					end
				end)
			end
			if opts.reload then
				add(items, "ui.refresh_view", "Reload diff", opts.reload)
			end
			if has_review_items then
				add(items, "pulls.review.diff.toggle_review_panel", "Toggle review panel", function()
					if session.toggle_review_panel then
						session.toggle_review_panel(true)
					end
				end)
			end

			if session.review then
				add(items, "ui.open_actions", "Review actions", function()
					actions.open(session)
				end)
				if can_complete and action_context and pull_actions.is_available("approve", action_context) then
					add(items, "pulls.review.approve", "Approve", function()
						actions.approve(session)
					end)
				end
				if can_complete and action_context and pull_actions.is_available("request_changes", action_context) then
					add(items, "pulls.review.request_changes", "Request changes", function()
						actions.request_changes(session)
					end)
				end
				if reviewable and (session.review.data.review.pending or reviews.start_review) then
					add(items, "pulls.review.submit_review", "Start / submit review", function()
						actions.start_or_submit(session)
					end)
				end
				add(items, "pulls.review.diff.toggle_comments", "Toggle comment display", function()
					session.expanded_overlays = not session.expanded_overlays
					session:render()
					session_api.notify(
						session,
						"info",
						session.expanded_overlays and "Review overlays expanded" or "Review overlays compact",
						1200
					)
				end)
				add(items, "ui.open_in_browser", "Open comment in browser", function()
					comments.open_in_browser(session, buf)
				end)
				if file_buffers[buf] and opts.add_file_comment then
					add(items, "pulls.review.diff.add_comment", "Add pending file comment", function()
						opts.add_file_comment(true)
					end)
					add(items, "pulls.review.diff.submit_comment", "Submit file comment", function()
						opts.add_file_comment(false)
					end)
				end
			end

			if has_review_items and content_buffer(session, buf) then
				add(items, "ui.show_details", "Open comment or note", function()
					with_item(session, buf, function()
						comments.open_at_cursor(session, buf)
					end, function()
						notes.open_at_cursor(session, buf)
					end)
				end)
				if session.review then
					add_range(
						items,
						"pulls.review.diff.add_comment",
						"Add pending inline comment",
						function(start, finish)
							comments.add_comment(session, buf, true, start, finish)
						end
					)
					add_range(
						items,
						"pulls.review.diff.submit_comment",
						"Submit inline comment",
						function(start, finish)
							comments.add_comment(session, buf, false, start, finish)
						end
					)
					if session.current and buf == session.current.right.buf then
						add_range(
							items,
							"pulls.review.diff.add_suggestion",
							"Add pending suggestion",
							function(start, finish)
								comments.add_suggestion(session, buf, true, start, finish)
							end
						)
						add_range(
							items,
							"pulls.review.diff.submit_suggestion",
							"Submit suggestion",
							function(start, finish)
								comments.add_suggestion(session, buf, false, start, finish)
							end
						)
					end
					add(items, "pulls.review.diff.toggle_resolved", "Toggle resolved", function()
						comments.toggle_resolved_at_cursor(session, buf)
					end)
					add(items, "pulls.review.diff.previous_comment", "Previous comment", function()
						comments.jump(session, buf, -1)
					end)
					add(items, "pulls.review.diff.next_comment", "Next comment", function()
						comments.jump(session, buf, 1)
					end)
				end
				add(items, "ui.delete", "Delete comment or note", function()
					with_item(session, buf, function()
						comments.delete_at_cursor(session, buf)
					end, function()
						notes.delete_at_cursor(session, buf)
					end)
				end)
				if session.note_target and session.current and buf == session.current.right.buf then
					add(items, "pulls.review.diff.add_note", "Add local note", function()
						notes.add_at_cursor(session, buf)
					end)
				end
				if session.review then
					add(items, "ui.toggle_fold", "Toggle review thread", function()
						if not comments.toggle_at_cursor(session, buf) and vim.fn.foldlevel(".") > 0 then
							vim.cmd.normal({ "za", bang = true })
						end
					end)
					add(items, "ui.toggle_all_folds", "Toggle all review threads", function()
						if not comments.toggle_all(session) and vim.fn.foldlevel(".") > 0 then
							vim.cmd.normal({ "zA", bang = true })
						end
					end)
				end
				if session.note_target then
					add(items, "pulls.review.diff.previous_note", "Previous note", function()
						notes.jump(session, -1)
					end)
					add(items, "pulls.review.diff.next_note", "Next note", function()
						notes.jump(session, 1)
					end)
				end
			end

			if opts.help_key then
				items[#items + 1] = {
					key = opts.help_key,
					desc = "Toggle Atlas help",
					callback = function()
						help.toggle({ buffer = buf })
					end,
					opts = { nowait = true, silent = true },
				}
			end
			help.register("Review", items, { buffer = buf, index = 110 })
		end
	end
end

return M
