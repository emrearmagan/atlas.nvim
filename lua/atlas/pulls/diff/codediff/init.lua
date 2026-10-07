-- Uses CodeDiff internals for now, so upstream changes can break this.
-- A public plugin API is planned: https://github.com/esmuellert/codediff.nvim/issues/267
local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local path = require("codediff.core.path")
local virtual_file = require("codediff.core.virtual_file")
local codediff = require("codediff.ui.view")
local inline = require("codediff.ui.view.inline_view")
local side_by_side = require("codediff.ui.view.side_by_side")
local annotation_ui = require("atlas.pulls.diff.ui.annotations")
local annotations = require("atlas.pulls.diff.codediff.annotations")
local keymaps = require("atlas.pulls.diff.codediff.keymaps")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local worktree = require("atlas.pulls.diff.worktree")
local winbar = require("atlas.pulls.diff.ui.winbar")
local has_refresh, refresh = pcall(require, "codediff.ui.refresh")

---@class AtlasDiffCodeDiffView: AtlasDiffView
---@field observer integer
---@field group integer
---@field loading_buf integer|nil
---@field on_done (fun(err?: string))|nil

---@param view AtlasDiffView
local function update_panes(view)
	local original_win, modified_win = lifecycle.get_windows(view.tabpage)
	view.right.win = modified_win or original_win
	view.right.buf = vim.api.nvim_win_get_buf(view.right.win)
	view.left.win = original_win ~= view.right.win and original_win or nil
	-- CodeDiff owns the hidden original buffer in inline mode.
	view.left.buf = view.left.win and vim.api.nvim_win_get_buf(view.left.win) or view.right.buf
end

---@param view AtlasDiffCodeDiffView
local function redraw(view)
	local session = lifecycle.get_session(view.tabpage)
	if view.loading_buf or not view.current_file or not session or not session.stored_diff_result then
		return
	end

	update_panes(view)
	local buf = session.single_side == "original" and session.original_bufnr or session.modified_bufnr
	-- Older CodeDiff updates can finish after we've already selected another file.
	if view.right.buf ~= buf then
		return
	end

	-- CodeDiff's inline revision buffer has no name for bufferlines or window lists.
	if vim.bo[buf].buftype == "nofile" and vim.api.nvim_buf_get_name(buf) == "" then
		vim.api.nvim_buf_set_name(
			buf,
			string.format("atlas-diff://%d/%d/%s", view.tabpage, buf, view.current_file.path)
		)
	end

	annotations.render(view, view.current_file, session)

	local on_done = view.on_done
	view.on_done = nil
	if on_done then
		on_done()
	end
end

---@param view AtlasDiffCodeDiffView
local function resize(view)
	layout.arrange(view.tabpage)
	redraw(view)
end

---@param view AtlasDiffCodeDiffView
local function observe_rendering(view)
	local last_result, last_buf, last_tick, last_width

	-- Single-file panes have no diff to wait for, just their Git contents.
	vim.api.nvim_create_autocmd("User", {
		group = view.group,
		pattern = "CodeDiffVirtualFileLoaded",
		callback = function(event)
			if event.data.buf == view.loading_buf then
				view.loading_buf = nil
				vim.schedule(function()
					redraw(view)
				end)
			end
		end,
	})

	-- CodeDiff's file-loaded event fires before rendering finishes.
	-- Observe its finished result during redraw, then draw our annotations afterwards.
	vim.api.nvim_set_decoration_provider(view.observer, {
		on_win = function(_, win, buf)
			local session = lifecycle.get_session(view.tabpage)
			if not session or win ~= (session.modified_win or session.original_win) then
				return false
			end

			local result = session.stored_diff_result
			if not view.current_file or not result then
				return false
			end

			-- Single-file panes get their result before their contents arrive.
			local tick = vim.api.nvim_buf_get_changedtick(buf)
			local width = vim.api.nvim_win_get_width(win)
			if result ~= last_result or buf ~= last_buf or tick ~= last_tick or width ~= last_width then
				last_result, last_buf, last_tick, last_width = result, buf, tick, width
				vim.schedule(function()
					if lifecycle.get_session(view.tabpage) == session then
						redraw(view)
					end
				end)
			end
			return false
		end,
	})
end

---@param view AtlasDiffCodeDiffView
---@param file AtlasDiffFile
---@param on_done fun(err?: string)
local function show_file(view, file, on_done)
	view.on_done = nil
	annotation_ui.close(view.tabpage)
	annotations.clear(view)

	local result = view.result
	local root = result.worktree_root or result.root
	local head_buf
	if result.worktree_root and not file.binary and file.status ~= "deleted" then
		head_buf = worktree.load(result.worktree_root, file.path)
		if head_buf then
			-- Our own file switches should not be handled as LSP jumps.
			view.right.buf = head_buf
		end
	end

	if file.status == "added" or file.status == "deleted" then
		-- Tell CodeDiff we're switching files so old refresh results are ignored.
		if has_refresh and refresh.begin then
			refresh.begin(view.tabpage)
		end

		local deleted = file.status == "deleted"
		---@type string|nil
		local revision = deleted and result.base_revision or result.head_revision
		if head_buf then
			view.loading_buf = nil
			revision = nil
		else
			local buf = vim.fn.bufadd(virtual_file.create_url(root, revision, file.path))
			if not vim.api.nvim_buf_is_loaded(buf) then
				view.loading_buf = buf
			elseif view.loading_buf ~= buf then
				view.loading_buf = nil
			end
		end

		if codediff.get_current_layout(view.tabpage) == "inline" then
			inline.show_single_file(view.tabpage, vim.fs.joinpath(root, file.path), {
				git_root = root,
				revision = revision,
				rel_path = file.path,
				side = deleted and "original" or "modified",
			})
		elseif head_buf then
			side_by_side.show_untracked_file(view.tabpage, vim.fs.joinpath(root, file.path))
		elseif deleted then
			-- These helpers show a single pane, even when they are in side-by-side mode.
			side_by_side.show_deleted_virtual_file(view.tabpage, root, file.path, revision)
		else
			side_by_side.show_added_virtual_file(view.tabpage, root, file.path, revision)
		end
	else
		view.loading_buf = nil
		local updated = codediff.update(view.tabpage, {
			git_root = root,
			original = path.make_ref(file.old_path or file.path, root),
			modified = path.make_ref(file.path, root),
			original_revision = result.base_revision,
			modified_revision = head_buf and "WORKING" or result.head_revision,
		}, config.options.diff.jump_to_first_change)

		if not updated then
			on_done("CodeDiff could not update the diff")
			return
		end
	end

	update_panes(view)

	view.callbacks.on_file(file)
	view.on_done = on_done
	redraw(view)
end

---@param view AtlasDiffCodeDiffView
local function setup_worktree(view)
	local root = view.result.worktree_root
	if not root then
		return
	end

	vim.api.nvim_create_autocmd("BufEnter", {
		group = view.group,
		callback = function(event)
			local buf = event.buf
			local name = vim.api.nvim_buf_get_name(buf)
			local relative = worktree.relative_path(root, name)
			if relative and not vim.bo[buf].modified then
				worktree.protect(buf)
			end
			if
				vim.api.nvim_get_current_win() ~= view.right.win
				or buf == view.right.buf
				or vim.bo[buf].buftype ~= ""
			then
				return
			end

			view.on_done = nil
			view.loading_buf = nil
			view.right.buf = buf
			annotation_ui.close(view.tabpage)
			annotations.clear(view)
			view.callbacks.on_file(nil)

			-- LSP sets the destination cursor after entering the buffer.
			vim.schedule(function()
				if not vim.api.nvim_win_is_valid(view.right.win) or vim.api.nvim_win_get_buf(view.right.win) ~= buf then
					return
				end

				local file
				for _, item in ipairs(view.result.files) do
					if item.path == relative then
						file = item
						break
					end
				end

				if not file then
					-- Use the same file on both sides so LSP destinations have no diff highlights.
					local target = path.make_ref(name, root)
					codediff.update(view.tabpage, {
						git_root = root,
						original = target,
						modified = target,
						original_revision = "WORKING",
						modified_revision = "WORKING",
					}, false)
					update_panes(view)
					return
				end

				local position = vim.api.nvim_win_call(view.right.win, vim.fn.winsaveview)
				show_file(view, file, function(err)
					if err then
						logger.logerror(
							"diff.show_file failed",
							{ root = view.result.root, path = file.path, error = err }
						)
						notify.error("Unable to open " .. file.path .. "\n\n" .. err, { vim_notify = true })
						return
					end

					vim.api.nvim_win_call(view.right.win, function()
						vim.fn.winrestview(position)
						vim.cmd("normal! zv")
					end)
				end)
			end)
		end,
	})
end

---@param result AtlasDiffResult
---@param callbacks AtlasDiffCallbacks
---@return AtlasDiffCodeDiffView
local function open(result, callbacks)
	local options = {
		panel = { name = "explorer" },
		git_root = result.worktree_root or result.root,
		original = path.empty(),
		modified = path.empty(),
		original_revision = result.base_revision,
		modified_revision = result.head_revision,
	}

	local previous_tab = vim.api.nvim_get_current_tabpage()
	local ok, state = pcall(function()
		local opened = codediff.create(options, "")
		---@cast opened table
		local tabpage = vim.api.nvim_win_get_tabpage(opened.modified_win)

		-- Empty panes need a valid diff result when returning to the tab.
		if not lifecycle.get_session(tabpage).stored_diff_result.changes then
			lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
		end
		-- Panel mode creates the empty panes; Atlas supplies the explorer afterwards.
		lifecycle.get_session(tabpage).panel = nil

		---@type AtlasDiffCodeDiffView
		local view = {
			tabpage = tabpage,
			result = result,
			callbacks = callbacks,
			annotations = {},
			expanded_threads = {},
			observer = vim.api.nvim_create_namespace("atlas.diff.codediff.observe." .. tabpage),
			group = vim.api.nvim_create_augroup("AtlasDiffCodeDiff" .. tabpage, { clear = true }),
			left = { buf = opened.original_buf, win = opened.original_win },
			right = { buf = opened.modified_buf, win = opened.modified_win },
		}
		observe_rendering(view)
		setup_worktree(view)

		-- CodeDiff clears both winbars on these events, so restore our file titles afterwards.
		vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType" }, {
			group = view.group,
			callback = function()
				local win = vim.api.nvim_get_current_win()
				if win == view.left.win or win == view.right.win then
					winbar.update(view)
				end
			end,
		})
		return view
	end)

	if ok then
		return state
	end

	-- CodeDiff could fail after opening its tab.
	-- so we use the new current tab to clean up what it left behind.. (hopefully)
	-- because otherwise the broken tab would stay open
	local tabpage = vim.api.nvim_get_current_tabpage()
	if tabpage ~= previous_tab then
		local session = lifecycle.get_session(tabpage)
		local buffers = session and { session.original_bufnr, session.modified_bufnr } or {}

		vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(tabpage) } })
		lifecycle.cleanup(tabpage)

		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
	end

	error(state, 0)
end

---@param view AtlasDiffCodeDiffView
---@return AtlasDiffSelection|nil, string|nil
local function get_selection(view)
	local file = view.current_file
	local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local left = win == view.left.win and buf == view.left.buf
	local right = win == view.right.win and buf == view.right.buf

	if not file or not (left or right) then
		return nil, "Select a line in the diff"
	end
	if file.binary then
		return nil, "Binary files do not have review lines"
	end

	local side = (left or file.status == "deleted") and "LEFT" or "RIGHT"
	local source = side == "LEFT" and "original" or "modified"
	local target = side == "LEFT" and "modified" or "original"
	local session = lifecycle.get_session(view.tabpage)
	if view.loading_buf or not session or not session.stored_diff_result or buf ~= session[source .. "_bufnr"] then
		return nil, "The diff is still loading"
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local first = vim.api.nvim_win_get_cursor(win)[1]
	local last = first
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		first = vim.fn.line("v")
		first, last = math.min(first, last), math.max(first, last)
		vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
	end

	local function position(line)
		local value = { from = side == "LEFT" and line or nil, to = side == "RIGHT" and line or nil }
		if file.status == "added" or file.status == "deleted" then
			return value
		end

		local offset = 0
		for _, change in ipairs(session.stored_diff_result.changes) do
			local current, other = change[source], change[target]
			if line < current.start_line then
				break
			end
			if line < current.end_line then
				return value
			end
			offset = offset + (other.end_line - other.start_line) - (current.end_line - current.start_line)
		end

		-- GitLab needs both positions for unchanged lines.
		if side == "LEFT" then
			value.to = line + offset
		else
			value.from = line + offset
		end
		return value
	end

	local inline_position = position(last)
	if first ~= last then
		local start = position(first)
		if (start.to ~= nil) ~= (inline_position.to ~= nil) then
			return nil, "The selected lines cannot be represented as one review range"
		end
		inline_position.start_from = start.from
		inline_position.start_to = start.to
	end
	inline_position.path = file.path
	inline_position.old_path = file.old_path
	inline_position.commit_hash = view.result.head_revision

	return { file = file, side = side, first = first, last = last, source_lines = lines, inline = inline_position }
end

---@param session AtlasDiffSession
---@param actions AtlasDiffKeymapActions
---@param groups AtlasDiffKeymapGroup[]
local function setup_keymaps(session, actions, groups)
	local view = session.view
	---@cast view AtlasDiffCodeDiffView
	keymaps.setup(session, actions, groups, {
		toggle_layout = function()
			local file = session.explorer.selected
			if file and (file.status == "added" or file.status == "deleted") then
				return
			end

			annotations.clear(view)
			codediff.toggle_layout(view.tabpage)
			update_panes(view)
			view.callbacks.on_file(session.explorer.selected)
		end,
	})
end

---@param view AtlasDiffCodeDiffView
local function dispose(view)
	vim.api.nvim_set_decoration_provider(view.observer, {})
	vim.api.nvim_del_augroup_by_id(view.group)
	annotations.clear(view)
	lifecycle.cleanup(view.tabpage)
end

---@type AtlasDiffRenderer
local M = {
	open = open,
	show_file = show_file,
	get_selection = get_selection,
	navigate_annotation = annotations.navigate,
	redraw = redraw,
	resize = resize,
	setup_keymaps = setup_keymaps,
	dispose = dispose,
}

return M
