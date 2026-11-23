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
---@field right_options table<string, any>|nil The real file's own window options, put back when it leaves the right pane.
---@field group integer
local Renderer = {}
Renderer.__index = Renderer

---@class AtlasDiffDocument
---@field file AtlasDiffFile
---@field contents { old: { lines: string[], endofline: boolean }, new: { lines: string[], endofline: boolean } }
---@field binary boolean
---@field buf integer|nil The real file shown on the right instead of a copy.
---@field hunks DiffHunk[] Used by inline mode and comment positions.
---@field split_hunks DiffHunk[] Used by side-by-side mode.

---@param file AtlasDiffFile
---@param contents { old: string, new: string }
---@param buf integer|nil
---@return AtlasDiffDocument
local function prepare_document(file, contents, buf)
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
		buf = not binary and buf or nil,
		hunks = hunks,
		split_hunks = split_hunks,
	}
end

local function setup_buffer(buf)
	vim.b[buf].atlas_diff = true
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.diagnostic.enable(false, { bufnr = buf })
end

local function setup_window(win)
	vim.w[win].atlas_diff = true
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
		vim.api.nvim_win_call(renderer.right.win, function()
			vim.cmd.diffoff({ bang = true })
		end)

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
local function set_content(renderer, buf, content, path, binary)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_name(buf, string.format("atlas-diff://%d/%d/%s", renderer.tabpage, buf, path))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
	vim.bo[buf].endofline = content.endofline
	vim.bo[buf].fixendofline = false

	-- No filetype, otherwise LSPs attach to this copy and stick around.
	vim.treesitter.stop(buf)
	vim.bo[buf].syntax = ""
	local filetype = not binary and vim.filetype.match({ filename = path, buf = buf })
	if filetype and not pcall(vim.treesitter.start, buf, vim.treesitter.language.get_lang(filetype) or filetype) then
		vim.bo[buf].syntax = filetype
	end

	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

---@param renderer AtlasDiffNativeRenderer
---@return string|nil
local function files_root(renderer)
	local session = renderer.session
	if session.source.kind == "worktree" then
		return session.range.root
	end
	return session.worktree_root
end

local function owns_buffer(renderer, buf)
	return buf == renderer.left.buf
		or buf == renderer.revision_buf
		or worktree.relative_path(files_root(renderer), vim.api.nvim_buf_get_name(buf)) ~= nil
end

local function release_buffer(renderer, buf)
	if vim.api.nvim_buf_is_valid(buf) and owns_buffer(renderer, buf) then
		render.clear(buf)
		annotations.clear(buf)
		help.remove_buffer(buf)
	end
end

-- Neovim remembers window options per buffer and starts the next window showing it with them,
-- so a real file gets its own back when it leaves the right pane.
local window_options = {
	"statusline",
	"winbar",
	"statuscolumn",
	"signcolumn",
	"number",
	"relativenumber",
	"fillchars",
	"winhighlight",
	"wrap",
	"diff",
	"scrollbind",
	"cursorbind",
	"foldmethod",
	"foldenable",
	"foldlevel",
	"foldminlines",
	"foldcolumn",
}

---@param renderer AtlasDiffNativeRenderer
local function save_window_options(renderer)
	renderer.right_options = {}
	for _, name in ipairs(window_options) do
		renderer.right_options[name] = vim.wo[renderer.right.win][0][name]
	end
end

---@param renderer AtlasDiffNativeRenderer
local function restore_window_options(renderer)
	local options = renderer.right_options
	renderer.right_options = nil
	if options and vim.api.nvim_win_is_valid(renderer.right.win) then
		for name, value in pairs(options) do
			vim.wo[renderer.right.win][0][name] = value
		end
	end
end

local function set_right_buffer(renderer, buf)
	if buf == renderer.right.buf and vim.api.nvim_win_get_buf(renderer.right.win) == buf then
		return
	end

	release_buffer(renderer, renderer.right.buf)
	restore_window_options(renderer)

	-- Our own buffer switches should not trigger another file load.
	renderer.right.buf = buf
	vim.api.nvim_win_set_buf(renderer.right.win, buf)
	if buf ~= renderer.revision_buf then
		save_window_options(renderer)
	end
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
	if file.status == "deleted" and not binary then
		right_content = old
	end

	set_right_buffer(renderer, document.buf or renderer.revision_buf)
	if renderer.right.buf == renderer.revision_buf then
		set_content(renderer, renderer.right.buf, right_content, file.path, binary)
	end

	if renderer.left.win then
		set_content(renderer, renderer.left.buf, old, file.old_path or file.path, binary)
	end

	render.render(renderer, document)
	renderer.annotations = annotations.render(renderer, document)
end

-- Staged files show the index, so they have no real file.
---@param session AtlasDiffSessionInternal
---@param file AtlasDiffFile
---@return integer|nil
local function right_buffer(session, file)
	if file.binary or file.status == "deleted" then
		return nil
	end
	if session.source.kind == "worktree" then
		return not file.staged and worktree.file_buffer(session.range.root, file.path) or nil
	end
	local root = session:head_worktree()
	return root and worktree.load(root, file.path) or nil
end

---@param file AtlasDiffFile
---@param on_done fun(err?: string)
function Renderer:show_file(file, on_done)
	local session = self.session
	annotation_ui.close(self.tabpage)
	self.requests.cancel()
	self.requests = requests.new()

	local function read(blob, path, missing)
		return function(done)
			if missing or file.binary then
				done("", nil)
				return
			end
			return diff.read_blob(session.range.root, blob, path, done)
		end
	end

	local buf = right_buffer(session, file)
	local new = read(file.new_blob, file.path, file.status == "deleted")
	if buf and session.source.kind == "worktree" then
		-- Read your buffer instead of the disk, so unsaved edits show up too.
		new = function(done)
			local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			done(vim.bo[buf].endofline and text .. "\n" or text, nil)
		end
	end

	self.requests.all({
		old = read(file.old_blob, file.old_path or file.path, file.status == "added"),
		new = new,
	}, function(contents, errors)
		local err = errors.old or errors.new
		if err then
			on_done(err)
			return
		end

		local rendered, document = pcall(function()
			local prepared = prepare_document(file, contents, buf)
			local shown = self.document
			-- Don't redraw a file that is already shown with the same content.
			if
				not shown
				or shown.file.path ~= file.path
				or shown.buf ~= prepared.buf
				or not vim.deep_equal(shown.contents, prepared.contents)
			then
				display(self, prepared)
			end
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

function Renderer:clear()
	self.requests.cancel()
	self.document = nil
	self.inline_hunk_lines = {}
	self.annotations = {}
	set_layout(self, "inline")
	set_right_buffer(self, self.revision_buf)
	vim.api.nvim_buf_clear_namespace(self.revision_buf, -1, 0, -1)
	set_content(self, self.revision_buf, { lines = {}, endofline = false }, "", true)
	vim.wo[self.right.win].winbar = ""
	render.message(self.right.win, "No changes")
	self.on_file(nil)
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
	release_buffer(self, self.right.buf)
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
	vim.api.nvim_create_autocmd("WinClosed", {
		group = renderer.group,
		pattern = tostring(renderer.right.win),
		callback = function()
			restore_window_options(renderer)
		end,
	})

	if renderer.session.source.kind == "worktree" then
		-- Other tabs can show your file from the working tree, so take the diff off it while this tab is hidden.
		vim.api.nvim_create_autocmd("TabLeave", {
			group = renderer.group,
			callback = function()
				local document = renderer.document
				if vim.api.nvim_get_current_tabpage() == renderer.tabpage and document and document.buf then
					release_buffer(renderer, document.buf)
					restore_window_options(renderer)
				end
			end,
		})

		-- The reverse of TabLeave: put the diff back on the file when we return.
		vim.api.nvim_create_autocmd("TabEnter", {
			group = renderer.group,
			callback = function()
				local document = renderer.document
				if vim.api.nvim_get_current_tabpage() ~= renderer.tabpage or not document or not document.buf then
					return
				end

				local view = vim.api.nvim_win_call(renderer.right.win, vim.fn.winsaveview)
				save_window_options(renderer)
				setup_window(renderer.right.win)
				render.render(renderer, document)
				renderer.annotations = annotations.render(renderer, document)
				renderer.on_file(document.file)
				vim.api.nvim_win_call(renderer.right.win, function()
					vim.fn.winrestview(view)
				end)
			end,
		})
	end

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
			local name = vim.api.nvim_buf_get_name(buf)
			if worktree.relative_path(renderer.session.worktree_root, name) and not vim.bo[buf].modified then
				worktree.protect(buf)
			end
			local path = worktree.relative_path(files_root(renderer), name)
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
					if item.path == path and not item.staged then
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

---@param session AtlasDiffSessionInternal
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
