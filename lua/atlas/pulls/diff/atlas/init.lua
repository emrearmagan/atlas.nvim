local annotation_ui = require("atlas.pulls.diff.ui.annotations")
local annotations = require("atlas.pulls.diff.atlas.annotations")
local diff = require("atlas.core.git.diff")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.pulls.diff.atlas.keymaps")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local render = require("atlas.pulls.diff.atlas.render")
local requests = require("atlas.core.requests")
local worktree = require("atlas.pulls.diff.worktree")
local winbar = require("atlas.pulls.diff.ui.winbar")

---@class AtlasDiffNativeRenderer: AtlasDiffRenderer
---@field requests AtlasRequestScope
---@field preferred_layout "inline"|"side-by-side"
---@field inline_hunk_lines integer[] Buffer lines to jump to in inline mode.
---@field document AtlasDiffDocument|nil
---@field revision_buf integer
---@field group integer
local Renderer = {}
Renderer.__index = Renderer

---@class AtlasDiffDocument
---@field file AtlasDiffFile
---@field contents { old: { lines: string[], endofline: boolean }, new: { lines: string[], endofline: boolean } }
---@field binary boolean
---@field hunks DiffHunk[] Used by inline mode and comment positions.
---@field split_hunks DiffHunk[] Used by side-by-side mode.

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

---@param renderer AtlasDiffNativeRenderer
local function resize(renderer)
	if not renderer.left.win then
		return
	end

	local width = vim.api.nvim_win_get_width(renderer.left.win) + vim.api.nvim_win_get_width(renderer.right.win)
	vim.api.nvim_win_set_width(renderer.left.win, math.floor(width / 2))
end

---@param renderer AtlasDiffNativeRenderer
---@param layout "inline"|"side-by-side"
local function set_layout(renderer, layout)
	if layout == "side-by-side" and not renderer.left.win then
		local win = vim.api.nvim_open_win(renderer.left.buf, false, { split = "left", win = renderer.right.win })
		renderer.left.win = win
		setup_window(win)
		resize(renderer)
	elseif layout == "inline" and renderer.left.win then
		for _, win in ipairs({ renderer.left.win, renderer.right.win }) do
			vim.api.nvim_win_call(win, function()
				vim.cmd.diffoff()
			end)
		end

		local win = renderer.left.win
		---@cast win integer
		if vim.api.nvim_get_current_win() == win then
			vim.api.nvim_set_current_win(renderer.right.win)
		end
		renderer.left.win = nil
		vim.api.nvim_win_close(win, true)
		setup_window(renderer.right.win)
	end
end

---@param renderer AtlasDiffRenderer
---@param content { lines: string[], endofline: boolean }
local function set_content(renderer, buf, content, path, revision, binary)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_name(buf, string.format("atlas-diff://%d/%d/%s/%s", renderer.tabpage, buf, revision, path))
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

local function owns_buffer(renderer, buf)
	return buf == renderer.left.buf
		or buf == renderer.revision_buf
		or worktree.relative_path(renderer.session.worktree_root, vim.api.nvim_buf_get_name(buf)) ~= nil
end

local function set_right_buffer(renderer, buf)
	if buf == renderer.right.buf and vim.api.nvim_win_get_buf(renderer.right.win) == buf then
		return
	end

	local previous = renderer.right.buf
	if vim.api.nvim_buf_is_valid(previous) and owns_buffer(renderer, previous) then
		render.clear(previous)
		annotations.clear(previous)
		help.remove_buffer(previous)
	end

	-- Our own buffer switches should not trigger another file load.
	renderer.right.buf = buf
	vim.api.nvim_win_set_buf(renderer.right.win, buf)
	setup_window(renderer.right.win)
end

---@param renderer AtlasDiffNativeRenderer
---@param document AtlasDiffDocument
local function display(renderer, document)
	local file = document.file
	local layout = renderer.preferred_layout
	if file.status == "added" or file.status == "deleted" then
		layout = "inline"
	end
	set_layout(renderer, layout)

	local old, new = document.contents.old, document.contents.new
	local binary = document.binary
	local right_content = new
	local right_revision = renderer.session.range.head_revision
	if file.status == "deleted" and not binary then
		right_content = old
		right_revision = renderer.session.range.base_revision
	end

	local right_buf = renderer.revision_buf
	local root = renderer.session:head_worktree()
	if root and not binary and file.status ~= "deleted" then
		right_buf = worktree.load(root, file.path) or right_buf
	end
	set_right_buffer(renderer, right_buf)
	if renderer.right.buf == renderer.revision_buf then
		set_content(renderer, renderer.right.buf, right_content, file.path, right_revision, binary)
	end

	if renderer.left.win then
		local old_path = file.old_path or file.path
		set_content(renderer, renderer.left.buf, old, old_path, renderer.session.range.base_revision, binary)
	end

	render.render(renderer, document)
	renderer.annotations = annotations.render(renderer, document)
end

---@param file AtlasDiffFile
---@param on_done fun(err?: string)
function Renderer:show_file(file, on_done)
	local session = self.session
	annotation_ui.close(self.tabpage)
	self.requests.cancel()
	self.requests = requests.new()

	local function read(revision, path, missing)
		return function(done)
			if missing or file.binary then
				done("", nil)
				return
			end
			return diff.read(session.range.root, revision, path, done)
		end
	end

	self.requests.all({
		old = read(session.range.base_revision, file.old_path or file.path, file.status == "added"),
		new = read(session.range.head_revision, file.path, file.status == "deleted"),
	}, function(contents, errors)
		local err = errors.old or errors.new
		if err then
			on_done(err)
			return
		end

		local rendered, document = pcall(function()
			local prepared = prepare_document(file, contents)
			display(self, prepared)
			return prepared
		end)
		if not rendered then
			on_done(tostring(document))
			return
		end

		self.document = document
		self.on_file(file)
		on_done(nil)
	end)
end

function Renderer:redraw()
	if self.document then
		self.annotations = annotations.render(self, self.document)
	end
end

---@param direction 1|-1
function Renderer:navigate_hunk(direction)
	if self.left.win then
		local motion = direction == 1 and "]c" or "[c"
		vim.cmd("silent! normal! " .. vim.v.count1 .. motion)
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local remaining = vim.v.count1
	local first = direction == 1 and 1 or #self.inline_hunk_lines
	local last = direction == 1 and #self.inline_hunk_lines or 1
	local target

	for index = first, last, direction do
		local line = self.inline_hunk_lines[index]
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

function Renderer:dispose()
	self.requests.cancel()
	vim.api.nvim_del_augroup_by_id(self.group)
	for _, buf in ipairs({ self.left.buf, self.revision_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

function Renderer:toggle_layout()
	local document = self.document
	if not document or document.file.status == "added" or document.file.status == "deleted" then
		return
	end

	self.preferred_layout = self.preferred_layout == "inline" and "side-by-side" or "inline"
	set_layout(self, self.preferred_layout)
	local positions = {}
	for _, pane in ipairs({ self.left, self.right }) do
		if pane.win then
			positions[pane.win] = vim.api.nvim_win_call(pane.win, vim.fn.winsaveview)
		end
	end

	display(self, document)
	self.on_file(self.current_file)
	for win, position in pairs(positions) do
		vim.api.nvim_win_call(win, function()
			if position.topline == 1 then
				position.topfill = vim.fn.winsaveview().topfill
			end
			vim.fn.winrestview(position)
		end)
	end
	if self.left.win then
		vim.api.nvim_win_call(self.right.win, function()
			vim.cmd.syncbind()
		end)
	end
end

function Renderer:toggle_compact()
	self.options.compact = not self.options.compact
	if self.document then
		render.compact(self, self.document)
	end
end

---@return AtlasDiffSelection|nil, string|nil
function Renderer:get_selection()
	local document = self.document
	local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
	local left = win == self.left.win and buf == self.left.buf
	local right = win == self.right.win and buf == self.right.buf

	if not document or not (left or right) then
		return nil, "Select a line in the diff"
	end
	if document.binary then
		return nil, "Binary files do not have review lines"
	end

	local file = document.file
	local side = (left or file.status == "deleted") and "LEFT" or "RIGHT"
	local lines = side == "LEFT" and document.contents.old.lines or document.contents.new.lines

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

	return annotation_ui.selection(self, file, side, lines, position)
end

local function setup_autocmds(renderer)
	vim.api.nvim_create_autocmd("WinResized", {
		group = renderer.group,
		callback = function()
			if
				not vim.api.nvim_win_is_valid(renderer.right.win)
				or (renderer.left.win and not vim.api.nvim_win_is_valid(renderer.left.win))
			then
				return
			end
			local windows = vim.v.event.windows
			---@cast windows integer[]
			if vim.tbl_contains(windows, renderer.right.win) or vim.tbl_contains(windows, renderer.left.win) then
				renderer:redraw()
			end
		end,
	})

	local function show_plain_file(buf, path)
		renderer.document = nil
		renderer.inline_hunk_lines = {}
		renderer.annotations = {}
		set_right_buffer(renderer, buf)
		set_layout(renderer, "inline")
		setup_window(renderer.right.win)
		if path then
			winbar.set(renderer.right.win, path)
		end
		renderer.on_file(nil)
	end

	vim.api.nvim_create_autocmd("BufEnter", {
		group = renderer.group,
		callback = function(event)
			local buf = event.buf
			local path = worktree.relative_path(renderer.session.worktree_root, vim.api.nvim_buf_get_name(buf))
			if path and not vim.bo[buf].modified then
				worktree.protect(buf)
			end
			if vim.api.nvim_get_current_win() ~= renderer.right.win or buf == renderer.right.buf then
				return
			end
			-- Stop an earlier read from replacing the file we just jumped to.
			renderer.requests.cancel()
			annotation_ui.close(renderer.tabpage)

			-- LSP positions the cursor after entering the buffer.
			vim.schedule(function()
				if
					not vim.api.nvim_win_is_valid(renderer.right.win)
					or vim.api.nvim_win_get_buf(renderer.right.win) ~= buf
				then
					return
				end

				local file
				for _, item in ipairs(renderer.session.files) do
					if item.path == path then
						file = item
						break
					end
				end
				if not file then
					show_plain_file(buf, path)
					return
				end

				local position = vim.api.nvim_win_call(renderer.right.win, vim.fn.winsaveview)
				renderer.document = nil
				renderer.annotations = {}
				renderer.inline_hunk_lines = {}
				set_right_buffer(renderer, buf)
				renderer:show_file(file, function(err)
					if err then
						show_plain_file(buf, path)
						logger.logerror("diff.show_file failed", {
							root = renderer.session.range.root,
							path = file.path,
							error = err,
						})
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
---@return AtlasDiffNativeRenderer
function Renderer.new(session, options, on_file)
	vim.cmd.tabnew()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local buf = vim.api.nvim_get_current_buf()
	local left_buf = vim.api.nvim_create_buf(false, true)

	local renderer = setmetatable({
		tabpage = tabpage,
		session = session,
		options = options,
		on_file = on_file,
		requests = requests.new(),
		preferred_layout = options.layout == "side-by-side" and "side-by-side" or "inline",
		inline_hunk_lines = {},
		annotations = {},
		expanded_threads = {},
		revision_buf = buf,
		group = vim.api.nvim_create_augroup("AtlasDiffNative" .. tabpage, { clear = true }),
		left = { buf = left_buf },
		right = { buf = buf, win = vim.api.nvim_get_current_win() },
	}, Renderer)

	local opened, err = pcall(function()
		setup_buffer(renderer.left.buf)
		setup_buffer(renderer.right.buf)
		setup_window(renderer.right.win)
		setup_autocmds(renderer)
	end)

	if not opened then
		vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(renderer.tabpage) } })
		renderer:dispose()
		error(err, 0)
	end

	return renderer
end

Renderer.navigate_annotation = annotations.navigate

function Renderer:resize()
	resize(self)
	self:redraw()
end

Renderer.setup_keymaps = keymaps.setup

return Renderer
