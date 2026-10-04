local annotation_ui = require("atlas.pulls.diff.ui.annotations")
local annotations = require("atlas.pulls.diff.atlas.annotations")
local diff = require("atlas.pulls.diff.diff")
local git = require("atlas.pulls.diff.git")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.pulls.diff.atlas.keymaps")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local render = require("atlas.pulls.diff.atlas.render")
local requests = require("atlas.core.requests")
local statusline = require("atlas.ui.statusline")
local worktree = require("atlas.pulls.diff.worktree")
local winbar = require("atlas.pulls.diff.ui.winbar")

---@class AtlasDiffNativeView: AtlasDiffView
---@field requests AtlasRequestScope
---@field preferred_layout "inline"|"side-by-side"
---@field inline_hunk_lines integer[] Buffer lines to jump to in inline mode.
---@field document AtlasDiffDocument|nil
---@field revision_buf integer
---@field group integer

---@class AtlasDiffDocument
---@field file AtlasDiffFile
---@field contents { old: { lines: string[], endofline: boolean }, new: { lines: string[], endofline: boolean } }
---@field binary boolean
---@field hunks integer[][] Old/new change ranges for inline rendering and review positions.
---@field split_hunks integer[][] Change ranges matching Neovim's split view and diffopt.

---@param file AtlasDiffFile
---@param contents { old: string, new: string }
---@return AtlasDiffDocument
local function prepare_document(file, contents)
	local old = contents.old:gsub("\r\n", "\n")
	local new = contents.new:gsub("\r\n", "\n")
	local binary = file.binary or old:find("\0", 1, true) ~= nil or new:find("\0", 1, true) ~= nil
	local hunks = {}
	local split_hunks = {}

	if binary then
		old = file.status == "added" and "" or "Binary file (base revision)\n"
		new = file.status == "deleted" and "Binary file deleted\n" or "Binary file (head revision)\n"
	elseif file.status ~= "added" and file.status ~= "deleted" then
		hunks, split_hunks = diff.compute(old, new)
	end

	local function prepare_content(content)
		local lines = vim.split(content, "\n", { plain = true })
		if lines[#lines] == "" then
			table.remove(lines)
		end

		return { lines = lines, endofline = content:sub(-1) == "\n" }
	end

	return {
		file = file,
		contents = { old = prepare_content(old), new = prepare_content(new) },
		binary = binary,
		hunks = hunks,
		split_hunks = split_hunks,
	}
end

local function setup_buffer(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
end

local function setup_window(win)
	local options = vim.wo[win][0]
	options.statuscolumn = vim.go.statuscolumn
	options.signcolumn = vim.go.signcolumn
	options.winbar = vim.go.winbar
	options.fillchars = "eob: "
	options.number = vim.go.number
	options.relativenumber = vim.go.relativenumber
	options.winhighlight = vim.go.winhighlight
	options.foldenable = false
	options.wrap = false
	options.diff = false
	options.scrollbind = false
	options.cursorbind = false
end

---@param view AtlasDiffNativeView
local function resize(view)
	if not view.left.win then
		return
	end

	local width = vim.api.nvim_win_get_width(view.left.win) + vim.api.nvim_win_get_width(view.right.win)
	vim.api.nvim_win_set_width(view.left.win, math.floor(width / 2))
end

---@param view AtlasDiffNativeView
---@param layout "inline"|"side-by-side"
local function set_layout(view, layout)
	if layout == "side-by-side" and not view.left.win then
		local win = vim.api.nvim_open_win(view.left.buf, false, { split = "left", win = view.right.win })
		view.left.win = win
		setup_window(win)
		statusline.inherit(win, view.right.win)
		resize(view)
	elseif layout == "inline" and view.left.win then
		for _, win in ipairs({ view.left.win, view.right.win }) do
			vim.api.nvim_win_call(win, function()
				vim.cmd.diffoff()
			end)
		end

		local win = view.left.win
		---@cast win integer
		if vim.api.nvim_get_current_win() == win then
			vim.api.nvim_set_current_win(view.right.win)
		end
		view.left.win = nil
		vim.api.nvim_win_close(win, true)
		setup_window(view.right.win)
	end
end

---@param view AtlasDiffView
---@param content { lines: string[], endofline: boolean }
local function set_content(view, buf, content, path, revision, binary)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_name(buf, string.format("atlas-diff://%d/%d/%s/%s", view.tabpage, buf, revision, path))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
	vim.bo[buf].endofline = content.endofline
	vim.bo[buf].fixendofline = false

	local filetype = not binary and vim.filetype.match({ filename = path, buf = buf }) or ""
	if vim.bo[buf].filetype ~= filetype then
		vim.treesitter.stop(buf)
		vim.bo[buf].filetype = filetype
	end

	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function owns_buffer(view, buf)
	return buf == view.left.buf
		or buf == view.revision_buf
		or worktree.relative_path(view.result.worktree_root, vim.api.nvim_buf_get_name(buf)) ~= nil
end

local function set_right_buffer(view, buf)
	if buf == view.right.buf and vim.api.nvim_win_get_buf(view.right.win) == buf then
		return
	end

	local previous = view.right.buf
	if vim.api.nvim_buf_is_valid(previous) and owns_buffer(view, previous) then
		render.clear(previous)
		annotations.clear(previous)
		help.remove_buffer(previous)
	end

	-- Our own buffer switches should not trigger another file load.
	view.right.buf = buf
	vim.api.nvim_win_set_buf(view.right.win, buf)
	setup_window(view.right.win)
end

---@param view AtlasDiffNativeView
---@param document AtlasDiffDocument
local function display(view, document)
	local file = document.file
	local layout = view.preferred_layout
	if file.status == "added" or file.status == "deleted" then
		layout = "inline"
	end
	set_layout(view, layout)

	local old, new = document.contents.old, document.contents.new
	local binary = document.binary
	local right_content = new
	local right_revision = view.result.head_revision
	if file.status == "deleted" and not binary then
		right_content = old
		right_revision = view.result.base_revision
	end

	local right_buf = view.revision_buf
	local root = view.result.worktree_root
	if root and not binary and file.status ~= "deleted" then
		right_buf = worktree.load(root, file.path) or right_buf
	end
	set_right_buffer(view, right_buf)
	if view.right.buf == view.revision_buf then
		set_content(view, view.right.buf, right_content, file.path, right_revision, binary)
	end

	if view.left.win then
		local old_path = file.old_path or file.path
		set_content(view, view.left.buf, old, old_path, view.result.base_revision, binary)
	end

	render.render(view, document)
	view.annotations = annotations.render(view, document)
end

---@param view AtlasDiffNativeView
---@param file AtlasDiffFile
---@param on_done fun(err?: string)
local function show_file(view, file, on_done)
	local result = view.result
	annotation_ui.close(view.tabpage)
	view.requests.cancel()
	view.requests = requests.new()

	local function read(revision, path, missing)
		return function(done)
			if missing or file.binary then
				done("", nil)
				return
			end
			return git.read(result.root, revision, path, done)
		end
	end

	view.requests.all({
		old = read(result.base_revision, file.old_path or file.path, file.status == "added"),
		new = read(result.head_revision, file.path, file.status == "deleted"),
	}, function(contents, errors)
		local err = errors.old or errors.new
		if err then
			on_done(err)
			return
		end

		local rendered, document = pcall(function()
			local prepared = prepare_document(file, contents)
			display(view, prepared)
			return prepared
		end)
		if not rendered then
			on_done(tostring(document))
			return
		end

		view.document = document
		view.callbacks.on_file(file)
		on_done(nil)
	end)
end

---@param view AtlasDiffNativeView
local function redraw(view)
	if view.document then
		view.annotations = annotations.render(view, view.document)
	end
end

---@param view AtlasDiffNativeView
---@param direction 1|-1
local function navigate_hunk(view, direction)
	if view.left.win then
		local motion = direction == 1 and "]c" or "[c"
		vim.cmd("silent! normal! " .. vim.v.count1 .. motion)
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local remaining = vim.v.count1
	local first = direction == 1 and 1 or #view.inline_hunk_lines
	local last = direction == 1 and #view.inline_hunk_lines or 1
	local target

	for index = first, last, direction do
		local line = view.inline_hunk_lines[index]
		if (direction == 1 and line > cursor) or (direction == -1 and line < cursor) then
			target = line
			remaining = remaining - 1
			if remaining == 0 then
				break
			end
		end
	end

	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		vim.cmd("normal! zv")
	end
end

---@param view AtlasDiffNativeView
local function dispose(view)
	view.requests.cancel()
	vim.api.nvim_del_augroup_by_id(view.group)
	for _, buf in ipairs({ view.left.buf, view.revision_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

---@param view AtlasDiffNativeView
local function toggle_layout(view)
	local document = view.document
	if not document or document.file.status == "added" or document.file.status == "deleted" then
		return
	end

	view.preferred_layout = view.preferred_layout == "inline" and "side-by-side" or "inline"
	set_layout(view, view.preferred_layout)
	local positions = {}
	for _, pane in ipairs({ view.left, view.right }) do
		if pane.win then
			positions[pane.win] = vim.api.nvim_win_call(pane.win, vim.fn.winsaveview)
		end
	end

	display(view, document)
	winbar.update(view)
	for win, position in pairs(positions) do
		vim.api.nvim_win_call(win, function()
			if position.topline == 1 then
				position.topfill = vim.fn.winsaveview().topfill
			end
			vim.fn.winrestview(position)
		end)
	end
	if view.left.win then
		vim.api.nvim_win_call(view.right.win, function()
			vim.cmd.syncbind()
		end)
	end
end

---@param view AtlasDiffNativeView
local function toggle_compact(view)
	view.result.options.compact = not view.result.options.compact
	if view.document then
		render.compact(view, view.document)
	end
end

---@param view AtlasDiffNativeView
---@return AtlasDiffSelection|nil, string|nil
local function get_selection(view)
	local document = view.document
	local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local left = win == view.left.win and buf == view.left.buf
	local right = win == view.right.win and buf == view.right.buf

	if not document or not (left or right) then
		return nil, "Select a line in the diff"
	end
	if document.binary then
		return nil, "Binary files do not have review lines"
	end

	local file = document.file
	local side = (left or file.status == "deleted") and "LEFT" or "RIGHT"
	local lines = side == "LEFT" and document.contents.old.lines or document.contents.new.lines
	local first = vim.api.nvim_win_get_cursor(win)[1]
	local last = first
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		first = vim.fn.line("v")
		first, last = math.min(first, last), math.max(first, last)
		vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
	end

	if last > #lines then
		return nil, "The selected lines are outside the file"
	end

	local function position(line)
		local from = side == "LEFT" and line or nil
		local to = side == "RIGHT" and line or nil
		if file.status ~= "added" and file.status ~= "deleted" then
			local opposite, hunk = diff.map_line(document.hunks, side, line)
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

local function setup_autocmds(view)
	vim.api.nvim_create_autocmd("WinResized", {
		group = view.group,
		callback = function()
			local windows = vim.v.event.windows
			---@cast windows integer[]
			if vim.tbl_contains(windows, view.right.win) or vim.tbl_contains(windows, view.left.win) then
				redraw(view)
			end
		end,
	})

	local function show_plain_file(buf, path)
		view.document = nil
		view.inline_hunk_lines = {}
		view.annotations = {}
		set_right_buffer(view, buf)
		set_layout(view, "inline")
		setup_window(view.right.win)
		if path then
			winbar.set(view.right.win, path)
		end
		view.callbacks.on_file(nil)
	end

	vim.api.nvim_create_autocmd("BufEnter", {
		group = view.group,
		callback = function(event)
			local buf = event.buf
			local path = worktree.relative_path(view.result.worktree_root, vim.api.nvim_buf_get_name(buf))
			if path and not vim.bo[buf].modified then
				worktree.protect(buf)
			end
			if vim.api.nvim_get_current_win() ~= view.right.win or buf == view.right.buf then
				return
			end
			-- Stop an earlier read from replacing the file we just jumped to.
			view.requests.cancel()
			annotation_ui.close(view.tabpage)

			-- LSP positions the cursor after entering the buffer.
			vim.schedule(function()
				if not vim.api.nvim_win_is_valid(view.right.win) or vim.api.nvim_win_get_buf(view.right.win) ~= buf then
					return
				end

				local file
				for _, item in ipairs(view.result.files) do
					if item.path == path then
						file = item
						break
					end
				end
				if not file then
					show_plain_file(buf, path)
					return
				end

				local position = vim.api.nvim_win_call(view.right.win, vim.fn.winsaveview)
				view.document = nil
				view.annotations = {}
				view.inline_hunk_lines = {}
				set_right_buffer(view, buf)
				show_file(view, file, function(err)
					if err then
						show_plain_file(buf, path)
						logger.logerror("diff.show_file failed", {
							root = view.result.root,
							path = file.path,
							error = err,
						})
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
---@return AtlasDiffNativeView
local function open(result, callbacks)
	vim.cmd.tabnew()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local buf = vim.api.nvim_get_current_buf()
	local left_buf = vim.api.nvim_create_buf(false, true)

	---@type AtlasDiffNativeView
	local view = {
		tabpage = tabpage,
		result = result,
		requests = requests.new(),
		preferred_layout = result.options.layout == "side-by-side" and "side-by-side" or "inline",
		inline_hunk_lines = {},
		annotations = {},
		expanded_threads = {},
		revision_buf = buf,
		group = vim.api.nvim_create_augroup("AtlasDiffNative" .. tabpage, { clear = true }),
		callbacks = callbacks,
		left = { buf = left_buf },
		right = { buf = buf, win = vim.api.nvim_get_current_win() },
	}

	local opened, err = pcall(function()
		setup_buffer(view.left.buf)
		setup_buffer(view.right.buf)
		setup_window(view.right.win)
		setup_autocmds(view)
	end)

	if not opened then
		vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(view.tabpage) } })
		dispose(view)
		error(err, 0)
	end

	return view
end

---@type AtlasDiffRenderer
local M = {
	open = open,
	show_file = show_file,
	get_selection = get_selection,
	navigate_annotation = annotations.navigate,
	redraw = redraw,
	resize = function(view)
		---@cast view AtlasDiffNativeView
		resize(view)
		redraw(view)
	end,
	setup_keymaps = function(session, actions, groups)
		local view = session.view
		---@cast view AtlasDiffNativeView
		keymaps.setup(session, actions, groups, {
			navigate_hunk = function(direction)
				navigate_hunk(view, direction)
			end,
			toggle_layout = function()
				toggle_layout(view)
			end,
			toggle_compact = function()
				toggle_compact(view)
			end,
		})
	end,
	dispose = dispose,
}

return M
