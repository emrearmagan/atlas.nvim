require("diffview")

local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local lib = require("diffview.lib")
local RevType = require("diffview.vcs.rev").RevType
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView
local annotation_ui = require("atlas.pulls.diffv2.ui.annotations")
local annotations = require("atlas.pulls.diffv2.diffview.annotations")
local diff = require("atlas.pulls.diffv2.diff")
local keymaps = require("atlas.pulls.diffv2.diffview.keymaps")

---@class AtlasDiffV2DiffviewView: AtlasDiffV2View
---@field diffview CDiffView
---@field group integer
---@field pending_file { file: AtlasDiffV2File, on_done: fun(err?: string) }|nil
---@field hunks integer[][]
---@field split_hunks integer[][]

local statuses = {
	added = "A",
	deleted = "D",
	modified = "M",
	renamed = "R",
	copied = "C",
	type_changed = "T",
}

---@param view AtlasDiffV2DiffviewView
local function update_panes(view)
	local layout = view.diffview.cur_layout
	view.right = { buf = vim.api.nvim_win_get_buf(layout.b.id), win = layout.b.id }
	view.left = layout.a and { buf = vim.api.nvim_win_get_buf(layout.a.id), win = layout.a.id }
		or { buf = view.right.buf }
end

---@param result AtlasDiffV2Result
---@param callbacks AtlasDiffV2Callbacks
---@return AtlasDiffV2DiffviewView
local function open(result, callbacks)
	local files = { working = {} }
	for _, file in ipairs(result.files) do
		files.working[#files.working + 1] = {
			path = file.path,
			oldpath = file.old_path,
			status = statuses[file.status],
		}
	end

	local diffview = CDiffView({
		git_root = result.root,
		left = GitRev(RevType.COMMIT, result.base_revision),
		right = GitRev(RevType.COMMIT, result.head_revision),
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

	local layout = diffview.cur_layout
	local right = { buf = vim.api.nvim_win_get_buf(layout.b.id), win = layout.b.id }
	---@type AtlasDiffV2DiffviewView
	local view = {
		tabpage = diffview.tabpage,
		result = result,
		callbacks = callbacks,
		diffview = diffview,
		group = vim.api.nvim_create_augroup("AtlasDiffV2Diffview" .. diffview.tabpage, { clear = true }),
		annotations = {},
		hunks = {},
		split_hunks = {},
		left = layout.a and { buf = vim.api.nvim_win_get_buf(layout.a.id), win = layout.a.id } or { buf = right.buf },
		right = right,
	}

	diffview.emitter:on("file_open_pre", function()
		annotation_ui.close(view.tabpage)
		annotations.clear(view)
	end)
	-- Diffview adjusts scrolling after this event on a file's first open.
	diffview.emitter:on(
		"file_open_post",
		vim.schedule_wrap(function(_, entry)
			if entry ~= diffview.cur_entry or not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				return
			end

			local pending = view.pending_file
			if pending and pending.file.path ~= entry.path then
				diffview:set_file_by_path(pending.file.path, false)
				return
			end
			view.pending_file = nil

			update_panes(view)
			local file = vim.iter(result.files):find(function(item)
				return item.path == entry.path
			end)
			local old = table.concat(vim.api.nvim_buf_get_lines(view.left.buf, 0, -1, false), "\n")
			local new = table.concat(vim.api.nvim_buf_get_lines(view.right.buf, 0, -1, false), "\n")
			view.hunks, view.split_hunks = diff.compute(old, new)
			callbacks.on_file(file)
			annotations.render(view)

			if pending then
				pending.on_done()
			end
		end)
	)

	vim.api.nvim_create_autocmd("WinClosed", {
		group = view.group,
		callback = function()
			-- Diffview replaces panes before file_open_post. Track them before Atlas handles the close.
			if diffview.cur_layout:is_valid() then
				update_panes(view)
			end
		end,
	})

	return view
end

---@param view AtlasDiffV2DiffviewView
---@param file AtlasDiffV2File
---@param on_done fun(err?: string)
local function show_file(view, file, on_done)
	local loading = view.pending_file ~= nil
	view.pending_file = { file = file, on_done = on_done }
	-- Let Diffview finish loading before opening the latest selected file.
	if loading then
		return
	end

	view.diffview:set_file_by_path(file.path, false)
end

---@param view AtlasDiffV2DiffviewView
---@return AtlasDiffV2Selection|nil, string|nil
local function get_selection(view)
	local file = view.current_file
	local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local left = win == view.left.win and buf == view.left.buf
	local right = win == view.right.win and buf == view.right.buf

	if not file or not (left or right) then
		return nil, "Select a line in the diff"
	end
	if view.pending_file then
		return nil, "The diff is still loading"
	end

	local layout = view.diffview.cur_layout
	local native_file = left and layout.a.file or layout.b.file
	if file.binary or native_file.binary then
		return nil, "Binary files do not have review lines"
	end
	if native_file.nulled then
		return nil, "The selected side has no file"
	end

	local side = left and "LEFT" or "RIGHT"
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
		local from = side == "LEFT" and line or nil
		local to = side == "RIGHT" and line or nil
		if file.status ~= "added" and file.status ~= "deleted" then
			local opposite, hunk = diff.map_line(view.hunks, side, line)
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

	local inline = position(last)
	if first ~= last then
		local start = position(first)
		if (start.to ~= nil) ~= (inline.to ~= nil) then
			return nil, "The selected lines cannot be represented as one review range"
		end
		inline.start_from = start.from
		inline.start_to = start.to
	end
	inline.path = file.path
	inline.old_path = file.old_path
	inline.commit_hash = view.result.head_revision

	return { file = file, side = side, first = first, last = last, source_lines = lines, inline = inline }
end

---@param session AtlasDiffV2Session
---@param bindings AtlasDiffV2Keymaps
local function setup_keymaps(session, bindings)
	keymaps.setup(session, bindings, { show_details = session.view.callbacks.show_details })
end

---@param view AtlasDiffV2DiffviewView
local function dispose(view)
	vim.api.nvim_del_augroup_by_id(view.group)
	annotations.clear(view)
	view.diffview:close()
	lib.dispose_view(view.diffview)
end

---@type AtlasDiffV2Renderer
local M = {
	open = open,
	show_file = show_file,
	redraw = annotations.render,
	get_selection = get_selection,
	navigate_annotation = annotations.navigate,
	resize = annotations.render,
	setup_keymaps = setup_keymaps,
	dispose = dispose,
}

return M
