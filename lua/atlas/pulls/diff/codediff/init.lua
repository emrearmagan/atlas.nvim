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

---@class AtlasDiffCodeDiffRenderer: AtlasDiffRenderer
---@field observer integer
---@field group integer
---@field loading_buf integer|nil
---@field on_done (fun(err?: string))|nil
local Renderer = {}
Renderer.__index = Renderer

---@param renderer AtlasDiffRenderer
local function update_panes(renderer)
	local original_win, modified_win = lifecycle.get_windows(renderer.tabpage)
	renderer.right.win = modified_win or original_win
	renderer.right.buf = vim.api.nvim_win_get_buf(renderer.right.win)
	renderer.left.win = original_win ~= renderer.right.win and original_win or nil
	-- CodeDiff owns the hidden original buffer in inline mode.
	renderer.left.buf = renderer.left.win and vim.api.nvim_win_get_buf(renderer.left.win) or renderer.right.buf
end

function Renderer:redraw()
	local session = lifecycle.get_session(self.tabpage)
	if self.loading_buf or not self.current_file or not session or not session.stored_diff_result then
		return
	end

	update_panes(self)
	local buf = session.single_side == "original" and session.original_bufnr or session.modified_bufnr
	-- Older CodeDiff updates can finish after we've already selected another file.
	if self.right.buf ~= buf then
		return
	end

	-- CodeDiff's inline revision buffer has no name for bufferlines or window lists.
	if vim.bo[buf].buftype == "nofile" and vim.api.nvim_buf_get_name(buf) == "" then
		vim.api.nvim_buf_set_name(
			buf,
			string.format("atlas-diff://%d/%d/%s", self.tabpage, buf, self.current_file.path)
		)
	end

	annotations.render(self, self.current_file, session)

	local on_done = self.on_done
	self.on_done = nil
	if on_done then
		on_done()
	end
end

function Renderer:resize()
	layout.arrange(self.tabpage)
	self:redraw()
end

---@param renderer AtlasDiffCodeDiffRenderer
local function observe_rendering(renderer)
	local last_result, last_buf, last_tick, last_width

	-- Single-file panes have no diff to wait for, just their Git contents.
	vim.api.nvim_create_autocmd("User", {
		group = renderer.group,
		pattern = "CodeDiffVirtualFileLoaded",
		callback = function(event)
			if event.data.buf == renderer.loading_buf then
				renderer.loading_buf = nil
				vim.schedule(function()
					renderer:redraw()
				end)
			end
		end,
	})

	-- CodeDiff's file-loaded event fires before rendering finishes.
	-- Observe its finished result during redraw, then draw our annotations afterwards.
	vim.api.nvim_set_decoration_provider(renderer.observer, {
		on_win = function(_, win, buf)
			local session = lifecycle.get_session(renderer.tabpage)
			if not session or win ~= (session.modified_win or session.original_win) then
				return false
			end

			local result = session.stored_diff_result
			if not renderer.current_file or not result then
				return false
			end

			-- Single-file panes get their result before their contents arrive.
			local tick = vim.api.nvim_buf_get_changedtick(buf)
			local width = vim.api.nvim_win_get_width(win)
			if result ~= last_result or buf ~= last_buf or tick ~= last_tick or width ~= last_width then
				last_result, last_buf, last_tick, last_width = result, buf, tick, width
				vim.schedule(function()
					if lifecycle.get_session(renderer.tabpage) == session then
						renderer:redraw()
					end
				end)
			end
			return false
		end,
	})
end

---@param file AtlasDiffFile
---@param on_done fun(err?: string)
function Renderer:show_file(file, on_done)
	self.on_done = nil
	annotation_ui.close(self.tabpage)
	annotations.clear(self)

	local root = self.session.worktree_root or self.session.range.root
	local head_buf
	if self.session.worktree_root and not file.binary and file.status ~= "deleted" then
		head_buf = worktree.load(self.session.worktree_root, file.path)
		if head_buf then
			-- Our own file switches should not be handled as LSP jumps.
			self.right.buf = head_buf
		end
	end

	if file.status == "added" or file.status == "deleted" then
		-- Tell CodeDiff we're switching files so old refresh results are ignored.
		if has_refresh and refresh.begin then
			refresh.begin(self.tabpage)
		end

		local deleted = file.status == "deleted"
		---@type string|nil
		local revision = deleted and self.session.range.base_revision or self.session.range.head_revision
		if head_buf then
			self.loading_buf = nil
			revision = nil
		else
			local buf = vim.fn.bufadd(virtual_file.create_url(root, revision, file.path))
			if not vim.api.nvim_buf_is_loaded(buf) then
				self.loading_buf = buf
			elseif self.loading_buf ~= buf then
				self.loading_buf = nil
			end
		end

		if codediff.get_current_layout(self.tabpage) == "inline" then
			inline.show_single_file(self.tabpage, vim.fs.joinpath(root, file.path), {
				git_root = root,
				revision = revision,
				rel_path = file.path,
				side = deleted and "original" or "modified",
			})
		elseif head_buf then
			side_by_side.show_untracked_file(self.tabpage, vim.fs.joinpath(root, file.path))
		elseif deleted then
			-- These helpers show a single pane, even when they are in side-by-side mode.
			side_by_side.show_deleted_virtual_file(self.tabpage, root, file.path, revision)
		else
			side_by_side.show_added_virtual_file(self.tabpage, root, file.path, revision)
		end
	else
		self.loading_buf = nil
		local updated = codediff.update(self.tabpage, {
			git_root = root,
			original = path.make_ref(file.old_path or file.path, root),
			modified = path.make_ref(file.path, root),
			original_revision = self.session.range.base_revision,
			modified_revision = head_buf and "WORKING" or self.session.range.head_revision,
		}, config.options.diff.jump_to_first_change)

		if not updated then
			on_done("CodeDiff could not update the diff")
			return
		end
	end

	update_panes(self)

	self.on_file(file)
	self.on_done = on_done
	self:redraw()
end

---@param renderer AtlasDiffCodeDiffRenderer
local function setup_worktree(renderer)
	local root = renderer.session.worktree_root
	if not root then
		return
	end

	vim.api.nvim_create_autocmd("BufEnter", {
		group = renderer.group,
		callback = function(event)
			local buf = event.buf
			local name = vim.api.nvim_buf_get_name(buf)
			local relative = worktree.relative_path(root, name)
			if relative and not vim.bo[buf].modified then
				worktree.protect(buf)
			end
			if
				vim.api.nvim_get_current_win() ~= renderer.right.win
				or buf == renderer.right.buf
				or vim.bo[buf].buftype ~= ""
			then
				return
			end

			renderer.on_done = nil
			renderer.loading_buf = nil
			renderer.right.buf = buf
			annotation_ui.close(renderer.tabpage)
			annotations.clear(renderer)
			renderer.on_file(nil)

			-- LSP sets the destination cursor after entering the buffer.
			vim.schedule(function()
				if
					not vim.api.nvim_win_is_valid(renderer.right.win)
					or vim.api.nvim_win_get_buf(renderer.right.win) ~= buf
				then
					return
				end

				local file
				for _, item in ipairs(renderer.session.files) do
					if item.path == relative then
						file = item
						break
					end
				end

				if not file then
					-- Use the same file on both sides so LSP destinations have no diff highlights.
					local target = path.make_ref(name, root)
					codediff.update(renderer.tabpage, {
						git_root = root,
						original = target,
						modified = target,
						original_revision = "WORKING",
						modified_revision = "WORKING",
					}, false)
					update_panes(renderer)
					return
				end

				local position = vim.api.nvim_win_call(renderer.right.win, vim.fn.winsaveview)
				renderer:show_file(file, function(err)
					if err then
						logger.logerror(
							"diff.show_file failed",
							{ root = renderer.session.range.root, path = file.path, error = err }
						)
						notify.error("Unable to open " .. file.path .. "\n\n" .. err, { vim_notify = true })
						return
					end

					vim.api.nvim_win_call(renderer.right.win, function()
						vim.fn.winrestview(position)
						vim.cmd("normal! zv")
					end)
				end)
			end)
		end,
	})
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffConfig
---@param on_file fun(file: AtlasDiffFile|nil)
---@return AtlasDiffCodeDiffRenderer
function Renderer.new(session, options, on_file)
	local codediff_options = {
		panel = { name = "explorer" },
		git_root = session.worktree_root or session.range.root,
		original = path.empty(),
		modified = path.empty(),
		original_revision = session.range.base_revision,
		modified_revision = session.range.head_revision,
	}

	local previous_tab = vim.api.nvim_get_current_tabpage()
	local ok, state = pcall(function()
		local opened = codediff.create(codediff_options, "")
		---@cast opened table
		local tabpage = vim.api.nvim_win_get_tabpage(opened.modified_win)

		-- Empty panes need a valid diff result when returning to the tab.
		if not lifecycle.get_session(tabpage).stored_diff_result.changes then
			lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
		end
		-- Panel mode creates the empty panes; Atlas supplies the explorer afterwards.
		lifecycle.get_session(tabpage).panel = nil

		local renderer = setmetatable({
			tabpage = tabpage,
			session = session,
			options = options,
			on_file = on_file,
			annotations = {},
			expanded_threads = {},
			observer = vim.api.nvim_create_namespace("atlas.diff.codediff.observe." .. tabpage),
			group = vim.api.nvim_create_augroup("AtlasDiffCodeDiff" .. tabpage, { clear = true }),
			left = { buf = opened.original_buf, win = opened.original_win },
			right = { buf = opened.modified_buf, win = opened.modified_win },
		}, Renderer)
		observe_rendering(renderer)
		setup_worktree(renderer)

		-- CodeDiff clears both winbars on these events, so restore our file titles afterwards.
		vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType" }, {
			group = renderer.group,
			callback = function()
				local win = vim.api.nvim_get_current_win()
				if win == renderer.left.win or win == renderer.right.win then
					winbar.update(renderer)
				end
			end,
		})
		return renderer
	end)

	if ok then
		return state
	end

	-- CodeDiff could fail after opening its tab.
	-- so we use the new current tab to clean up what it left behind.. (hopefully)
	-- because otherwise the broken tab would stay open
	local tabpage = vim.api.nvim_get_current_tabpage()
	if tabpage ~= previous_tab then
		local codediff_session = lifecycle.get_session(tabpage)
		local buffers = codediff_session and { codediff_session.original_bufnr, codediff_session.modified_bufnr } or {}

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

---@return AtlasDiffSelection|nil, string|nil
function Renderer:get_selection()
	local file = self.current_file
	local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local left = win == self.left.win and buf == self.left.buf
	local right = win == self.right.win and buf == self.right.buf

	if not file or not (left or right) then
		return nil, "Select a line in the diff"
	end
	if file.binary then
		return nil, "Binary files do not have review lines"
	end

	local side = (left or file.status == "deleted") and "LEFT" or "RIGHT"
	local source = side == "LEFT" and "original" or "modified"
	local target = side == "LEFT" and "modified" or "original"
	local session = lifecycle.get_session(self.tabpage)
	if self.loading_buf or not session or not session.stored_diff_result or buf ~= session[source .. "_bufnr"] then
		return nil, "The diff is still loading"
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

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

	return annotation_ui.selection(self, file, side, lines, position)
end

function Renderer:toggle_layout()
	local file = self.current_file
	if file and (file.status == "added" or file.status == "deleted") then
		return
	end

	annotations.clear(self)
	codediff.toggle_layout(self.tabpage)
	update_panes(self)
	self.on_file(self.current_file)
end

function Renderer:dispose()
	vim.api.nvim_set_decoration_provider(self.observer, {})
	vim.api.nvim_del_augroup_by_id(self.group)
	annotations.clear(self)
	lifecycle.cleanup(self.tabpage)
end

Renderer.navigate_annotation = annotations.navigate
Renderer.setup_keymaps = keymaps.setup

return Renderer
