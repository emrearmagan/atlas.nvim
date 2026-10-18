require("diffview")

local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local lib = require("diffview.lib")
local RevType = require("diffview.vcs.rev").RevType
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView
local annotation_ui = require("atlas.pulls.diff.ui.annotations")
local annotations = require("atlas.pulls.diff.diffview.annotations")
local diff = require("atlas.pulls.diff.diff")
local keymaps = require("atlas.pulls.diff.diffview.keymaps")

---@class AtlasDiffDiffviewRenderer: AtlasDiffRenderer
---@field diffview CDiffView
---@field group integer
---@field pending_file { file: AtlasDiffFile, on_done: fun(err?: string) }|nil
---@field hunks integer[][]
---@field split_hunks integer[][]
local Renderer = {}
Renderer.__index = Renderer

local statuses = {
	added = "A",
	deleted = "D",
	modified = "M",
	renamed = "R",
	copied = "C",
	type_changed = "T",
}

---@param renderer AtlasDiffDiffviewRenderer
local function update_panes(renderer)
	local layout = renderer.diffview.cur_layout
	renderer.right = { buf = vim.api.nvim_win_get_buf(layout.b.id), win = layout.b.id }
	renderer.left = layout.a and { buf = vim.api.nvim_win_get_buf(layout.a.id), win = layout.a.id }
		or { buf = renderer.right.buf }
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffConfig
---@param on_file fun(file: AtlasDiffFile|nil)
---@return AtlasDiffDiffviewRenderer
function Renderer.new(session, options, on_file)
	local files = { working = {} }
	for _, file in ipairs(session.files) do
		files.working[#files.working + 1] = {
			path = file.path,
			oldpath = file.old_path,
			status = statuses[file.status],
		}
	end

	local diffview = CDiffView({
		git_root = session.range.root,
		left = GitRev(RevType.COMMIT, session.range.base_revision),
		right = GitRev(RevType.COMMIT, session.range.head_revision),
		files = files,
		update_files = function()
			return files
		end,
	})
	for _, entry in diffview.files:iter() do
		-- Diffview only handles deleted right sides automatically for local/index diffs.
		entry.layout.b.file.nulled = entry.status == "D"
	end

	diffview.emitter:on("post_layout", function()
		diffview.cur_layout:open_null()
		diffview.panel:close()
	end)

	lib.add_view(diffview)
	local ok, err = pcall(function()
		diffview:open()
	end)
	if not ok then
		if diffview.commit_log_panel then
			diffview:close()
		else
			-- DiffView:close() requires the panel created after its layout opens.
			StandardView.close(diffview)
		end
		lib.dispose_view(diffview)
		error(err, 0)
	end

	local renderer = setmetatable({
		tabpage = diffview.tabpage,
		session = session,
		options = options,
		on_file = on_file,
		diffview = diffview,
		group = vim.api.nvim_create_augroup("AtlasDiffDiffview" .. diffview.tabpage, { clear = true }),
		annotations = {},
		expanded_threads = {},
		hunks = {},
		split_hunks = {},
	}, Renderer)
	update_panes(renderer)

	diffview.emitter:on("file_open_pre", function()
		annotation_ui.close(renderer.tabpage)
		annotations.clear(renderer)
	end)
	-- Diffview adjusts scrolling after this event on a file's first open.
	diffview.emitter:on(
		"file_open_post",
		vim.schedule_wrap(function(_, entry)
			if entry ~= diffview.cur_entry or not vim.api.nvim_tabpage_is_valid(renderer.tabpage) then
				return
			end

			local pending = renderer.pending_file
			if pending and pending.file.path ~= entry.path then
				diffview:set_file_by_path(pending.file.path, false)
				return
			end
			renderer.pending_file = nil

			update_panes(renderer)
			local file = vim.iter(session.files):find(function(item)
				return item.path == entry.path
			end)
			local old = table.concat(vim.api.nvim_buf_get_lines(renderer.left.buf, 0, -1, false), "\n")
			local new = table.concat(vim.api.nvim_buf_get_lines(renderer.right.buf, 0, -1, false), "\n")
			renderer.hunks, renderer.split_hunks = diff.compute(old, new)
			renderer.on_file(file)
			annotations.render(renderer)

			if pending then
				pending.on_done()
			end
		end)
	)

	vim.api.nvim_create_autocmd("WinClosed", {
		group = renderer.group,
		callback = function()
			-- Diffview replaces panes before file_open_post. Track them before Atlas handles the close.
			if diffview.cur_layout:is_valid() then
				update_panes(renderer)
			end
		end,
	})

	return renderer
end

---@param file AtlasDiffFile
---@param on_done fun(err?: string)
function Renderer:show_file(file, on_done)
	local loading = self.pending_file ~= nil
	self.pending_file = { file = file, on_done = on_done }
	-- Let Diffview finish loading before opening the latest selected file.
	if loading then
		return
	end

	self.diffview:set_file_by_path(file.path, false)
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
	if self.pending_file then
		return nil, "The diff is still loading"
	end

	local layout = self.diffview.cur_layout
	local native_file = left and layout.a.file or layout.b.file
	if file.binary or native_file.binary then
		return nil, "Binary files do not have review lines"
	end
	if native_file.nulled then
		return nil, "The selected side has no file"
	end

	local side = left and "LEFT" or "RIGHT"
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	local function position(line)
		local from = side == "LEFT" and line or nil
		local to = side == "RIGHT" and line or nil
		if file.status ~= "added" and file.status ~= "deleted" then
			local opposite, hunk = diff.map_line(self.hunks, side, line)
			-- GitLab needs both positions for unchanged lines.
			if not hunk then
				if side == "LEFT" then
					to = opposite
				else
					from = opposite
				end
			end
		end
		return { from = from, to = to }
	end

	return annotation_ui.selection(self, file, side, lines, position)
end

function Renderer:dispose()
	vim.api.nvim_del_augroup_by_id(self.group)
	annotations.clear(self)
	self.diffview:close()
	lib.dispose_view(self.diffview)
end

Renderer.redraw = annotations.render
Renderer.navigate_annotation = annotations.navigate
Renderer.resize = annotations.render
Renderer.setup_keymaps = keymaps.setup

return Renderer
