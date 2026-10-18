local icons = require("atlas.ui.shared.icons")
local info = require("atlas.ui.popups.info")
local utils = require("atlas.ui.shared.utils")
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

---@class AtlasDiffExplorer
---@field buf integer
---@field win integer|nil
---@field group integer
---@field files AtlasDiffFile[] All files in navigation order, including collapsed descendants.
---@field source AtlasDiffFile[]
---@field options AtlasPullsDiffExplorerConfig
---@field rows { file?: AtlasDiffFile, path?: string, section?: string, header?: boolean, label?: string, prefix?: string }[]
---@field collapsed table<string, table<string, boolean>>
---@field flatten_dirs boolean
---@field reviewed_files table<string, boolean>|nil
---@field annotated_paths table<string, { comments?: boolean, notes?: boolean }>
---@field selected AtlasDiffFile|nil
---@field cursor_row integer|nil
---@field on_select fun(file: AtlasDiffFile, focus?: boolean)
local Explorer = {}
Explorer.__index = Explorer

local namespace = vim.api.nvim_create_namespace("atlas.diff.explorer")
local selection_namespace = vim.api.nvim_create_namespace("atlas.diff.explorer.selection")

local statuses = {
	added = { "A", "DiagnosticOk" },
	modified = { "M", "DiagnosticWarn" },
	deleted = { "D", "DiagnosticError" },
	renamed = { "R", "DiagnosticInfo" },
	copied = { "C", "DiagnosticInfo" },
	type_changed = { "T", "DiagnosticWarn" },
}

---@param files AtlasDiffFile[]
---@param ignore_patterns string[]|nil
---@return AtlasDiffFile[]
local function visible_files(files, ignore_patterns)
	local patterns = {}
	for _, pattern in ipairs(ignore_patterns or {}) do
		patterns[#patterns + 1] = vim.regex(vim.fn.glob2regpat(pattern))
	end

	local filtered = {}
	for _, file in ipairs(files) do
		local ignored = false
		for _, pattern in ipairs(patterns) do
			if pattern:match_str(file.path) then
				ignored = true
				break
			end
		end

		if not ignored then
			filtered[#filtered + 1] = file
		end
	end

	table.sort(filtered, function(a, b)
		return a.path < b.path
	end)
	return filtered
end

local function width(state)
	return math.min(state.options.width, math.max(20, vim.o.columns - 40))
end

local function current_row(state)
	if state.win then
		return vim.api.nvim_win_get_cursor(state.win)[1]
	end

	return state.cursor_row
end

---@param files AtlasDiffFile[]
local function tree(files)
	local root = { path = "", folders = {}, files = {} }
	for _, file in ipairs(files) do
		local node = root
		for name in file.path:gmatch("([^/]+)/") do
			local child = node.folders[name]
			if not child then
				child = { name = name, path = node.path .. name .. "/", folders = {}, files = {} }
				node.folders[name] = child
			end
			node = child
		end
		node.files[#node.files + 1] = file
	end

	return root
end

---@param state AtlasDiffExplorer
local function build_rows(state)
	local sections = { files = {}, reviewed = {} }
	for _, file in ipairs(state.source) do
		local section = state.reviewed_files and state.reviewed_files[file.path] and sections.reviewed or sections.files
		section[#section + 1] = file
	end

	local rows, ordered = {}, {}

	local function append_files(files, section, prefix, visible)
		for index, file in ipairs(files) do
			ordered[#ordered + 1] = file
			if visible then
				local branch = state.options.grouped and (index == #files and "└ " or "├ ") or "  "
				rows[#rows + 1] = { file = file, section = section, prefix = prefix .. branch }
			end
		end
	end

	local function visit(node, section, prefix, visible)
		local folders = vim.fn.sort(vim.tbl_keys(node.folders))
		for index, key in ipairs(folders) do
			local child = node.folders[key]
			local label = child.name
			while state.flatten_dirs and #child.files == 0 and vim.tbl_count(child.folders) == 1 do
				local _, next_child = next(child.folders)
				---@cast next_child table
				child = next_child
				label = label .. "/" .. child.name
			end

			local last = index == #folders and #node.files == 0
			if visible then
				rows[#rows + 1] = {
					path = child.path,
					section = section,
					label = label,
					prefix = prefix .. (last and "└ " or "├ "),
				}
			end
			visit(
				child,
				section,
				prefix .. (last and "  " or "│ "),
				visible and not state.collapsed[section][child.path]
			)
		end

		append_files(node.files, section, prefix, visible)
	end

	local function append_section(section, title)
		local files = sections[section]
		rows[#rows + 1] = { header = true, section = section, label = " " .. title .. " (" .. #files .. ")" }
		if state.options.grouped then
			visit(tree(files), section, "", true)
		else
			append_files(files, section, "", true)
		end
	end

	append_section("files", "Files")
	if #state.source == 0 then
		rows[#rows + 1] = { label = " No changed files" }
	end
	if state.reviewed_files then
		rows[#rows + 1] = { label = "" }
		append_section("reviewed", "Reviewed")
	end

	return rows, ordered
end

---@param file AtlasDiffFile
local function file_chunks(state, file, prefix, available)
	local name = file.path:match("[^/]+$") or file.path
	local icon, icon_hl = icons.get("file")
	if has_devicons then
		local glyph, highlight = devicons.get_icon(name, nil, { default = true })
		icon, icon_hl = glyph or icon, highlight or icon_hl
	end

	local marker = statuses[file.status] or { "?", "AtlasTextMuted" }
	local suffix = {}
	if file.binary then
		suffix[#suffix + 1] = { "bin ", "AtlasTextMuted" }
	else
		if (file.additions or 0) > 0 then
			suffix[#suffix + 1] = { "+" .. file.additions .. " ", "AtlasTextPositive" }
		end
		if (file.deletions or 0) > 0 then
			suffix[#suffix + 1] = { "-" .. file.deletions .. " ", "AtlasLogError" }
		end
	end
	suffix[#suffix + 1] = marker

	local suffix_width = 0
	for _, part in ipairs(suffix) do
		suffix_width = suffix_width + vim.fn.strdisplaywidth(part[1])
	end

	local chunks = { { prefix, "AtlasTextMuted" } }
	local annotation = state.annotated_paths[file.path]
	local previous_annotation = state.annotated_paths[file.old_path]
	if annotation and annotation.comments or previous_annotation and previous_annotation.comments then
		local glyph = icons.get("comment")
		chunks[#chunks + 1] = { glyph .. " ", "AtlasLogInfo" }
	end
	if annotation and annotation.notes or previous_annotation and previous_annotation.notes then
		local glyph, highlight = icons.get("pin")
		chunks[#chunks + 1] = { glyph .. " ", highlight }
	end
	chunks[#chunks + 1] = { icon .. " ", icon_hl }

	local remaining = available - 1
	for _, chunk in ipairs(chunks) do
		remaining = remaining - vim.fn.strdisplaywidth(chunk[1])
	end

	local label = vim.fn.strtrans(name)
	if vim.fn.strdisplaywidth(label) + suffix_width + 1 > remaining then
		suffix, suffix_width = { marker }, 1
	end

	label = utils.truncate(label, math.max(1, remaining - suffix_width - 1))
	chunks[#chunks + 1] = { label, "Normal" }
	remaining = remaining - vim.fn.strdisplaywidth(label)

	local parent = not state.options.grouped and file.path:match("^(.*)/[^/]+$")
	local path_width = remaining - suffix_width - 2
	if parent and path_width > 2 then
		local directory = utils.truncate(vim.fn.strtrans(parent .. "/"), path_width)
		chunks[#chunks + 1] = { " " .. directory, "AtlasTextMuted" }
		remaining = remaining - vim.fn.strdisplaywidth(directory) - 1
	end

	chunks[#chunks + 1] = { string.rep(" ", math.max(1, remaining - suffix_width)), "Normal" }
	vim.list_extend(chunks, suffix)

	return chunks
end

local function row_chunks(state, row, available)
	if row.file then
		return file_chunks(state, row.file, row.prefix, available)
	end

	if row.path then
		local collapsed = state.collapsed[row.section][row.path]
		local icon, highlight = icons.get(collapsed and "folder_closed" or "folder_open")
		local label = utils.truncate(
			vim.fn.strtrans(row.label),
			math.max(1, available - vim.fn.strdisplaywidth(row.prefix .. icon) - 2)
		)
		return { { row.prefix, "AtlasTextMuted" }, { icon .. " ", highlight }, { label, "AtlasLogInfo" } }
	end

	local chunks = { { row.label, row.header and "AtlasLogInfo" or "AtlasTextMuted" } }
	if row.header and row.section == "files" then
		local additions, deletions = 0, 0
		for _, file in ipairs(state.source) do
			additions = additions + (file.additions or 0)
			deletions = deletions + (file.deletions or 0)
		end

		local added, removed = "+" .. additions, "-" .. deletions
		local padding = available - #row.label - #added - #removed - 2
		if padding > 0 then
			vim.list_extend(chunks, {
				{ string.rep(" ", padding), "Normal" },
				{ added, "AtlasTextPositive" },
				{ " ", "Normal" },
				{ removed, "AtlasLogError" },
			})
		end
	end

	return chunks
end

local function highlight_selection(state)
	vim.api.nvim_buf_clear_namespace(state.buf, selection_namespace, 0, -1)
	for row, item in pairs(state.rows) do
		if item.file and item.file == state.selected then
			vim.api.nvim_buf_set_extmark(state.buf, selection_namespace, row - 1, 0, {
				line_hl_group = "Visual",
				priority = 90,
			})
			return row
		end
	end
end

local function render(state, preferred)
	local current_line = current_row(state)
	local view = state.win and vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
	local before = preferred or state.rows[current_line]
	local available = state.win and vim.api.nvim_win_get_width(state.win) or width(state)
	local lines, spans = {}, {}
	local cursor

	state.rows, state.files = build_rows(state)
	for row, item in ipairs(state.rows) do
		local text = ""
		for _, chunk in ipairs(row_chunks(state, item, available)) do
			if chunk[1] ~= "" then
				spans[#spans + 1] = { row - 1, #text, #text + #chunk[1], chunk[2] }
				text = text .. chunk[1]
			end
		end

		lines[row] = text
		if
			before
			and (
				item.file and item.file == before.file
				or item.path and item.path == before.path and item.section == before.section
				or item.header and before.header and item.section == before.section
			)
		then
			cursor = row
		end
	end

	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span[1], span[2], { end_col = span[3], hl_group = span[4] })
	end
	highlight_selection(state)

	state.cursor_row = cursor or math.min(math.max(2, current_line or 2), #lines)
	if view then
		view.lnum = state.cursor_row
		vim.api.nvim_win_call(state.win, function()
			vim.fn.winrestview(view)
		end)
	end
end

---@param file AtlasDiffFile
local function expand_parents(state, file)
	local section = state.reviewed_files and state.reviewed_files[file.path] and "reviewed" or "files"
	for parent in pairs(state.collapsed[section]) do
		if file.path:sub(1, #parent) == parent then
			state.collapsed[section][parent] = nil
		end
	end
end

---@param review_data PullsReviewData|nil
---@param notes AtlasNote[]|nil
---@return table<string, { comments?: boolean, notes?: boolean }>
local function collect_annotations(review_data, notes)
	local annotations = {}
	for _, items in ipairs({ review_data and review_data.comments or {}, review_data and review_data.tasks or {} }) do
		for _, comment in ipairs(items) do
			local target = comment.file or comment.inline
			if target then
				annotations[target.path] = annotations[target.path] or {}
				annotations[target.path].comments = true
			end
		end
	end

	for _, note in ipairs(notes or {}) do
		annotations[note.file_path] = annotations[note.file_path] or {}
		annotations[note.file_path].notes = true
	end

	return annotations
end

---@param reviewed_files table<string, boolean>|nil
---@param review_data PullsReviewData|nil
---@param notes AtlasNote[]|nil
function Explorer:update(reviewed_files, review_data, notes)
	self.reviewed_files = reviewed_files
	self.annotated_paths = collect_annotations(review_data, notes)
	render(self)
end

---@param files AtlasDiffFile[]
function Explorer:set_files(files)
	self.source = visible_files(files, self.options.ignore)
	self.selected = nil
	render(self)
end

---@return AtlasDiffFile|nil
function Explorer:current_file()
	local row = self.rows[current_row(self)]
	return row and row.file
end

---@return integer|nil
function Explorer:current_index()
	local current = self.selected
	if vim.api.nvim_get_current_win() == self.win then
		current = self:current_file() or current
	end

	for index, file in ipairs(self.files) do
		if file == current then
			return index
		end
	end
end

---@param file AtlasDiffFile|nil
function Explorer:reveal(file)
	file = vim.tbl_contains(self.files, file) and file or nil
	self.selected = file
	local row = highlight_selection(self)
	if not file then
		return
	end

	if not row then
		expand_parents(self, file)
		render(self, { file = file })
		return
	end

	self.cursor_row = row
	if self.win then
		vim.api.nvim_win_call(self.win, function()
			local view = vim.fn.winsaveview()
			view.lnum = row
			vim.fn.winrestview(view)
		end)
	end
end

function Explorer:show_details()
	info.toggle({
		source_win = self.win,
		content = function(line)
			local row = self.rows[line]
			local path = row and (row.path or row.file and row.file.path)
			if not path then
				return
			end

			local file = row.file
			if file and file.status == "renamed" and file.old_path then
				return {
					title = " Rename ",
					lines = { "From: " .. vim.fn.strtrans(file.old_path), "To:   " .. vim.fn.strtrans(file.path) },
				}
			end

			return { title = " Path ", lines = { vim.fn.strtrans(path) } }
		end,
	})
end

local function current_folder(state)
	local row = state.rows[current_row(state)]
	if row and row.file then
		local parent = row.file.path:match("^.*/")
		row = vim.iter(state.rows):find(function(item)
			return item.path ~= nil and item.path == parent and item.section == row.section
		end)
	end

	return row and row.path and row
end

---@return AtlasDiffFile[]
function Explorer:files_under_cursor()
	local row = self.rows[current_row(self)]
	if not row or not (row.path or row.header) then
		return {}
	end

	local prefix = row.path or ""
	return vim.tbl_filter(function(file)
		local section = self.reviewed_files and self.reviewed_files[file.path] and "reviewed" or "files"
		return section == row.section and file.path:sub(1, #prefix) == prefix
	end, self.source)
end

---@param collapsed boolean
function Explorer:set_folder_collapsed(collapsed)
	local row = current_folder(self)
	if row then
		self.collapsed[row.section][row.path] = collapsed or nil
		render(self, row)
	end
end

function Explorer:toggle_folder()
	local row = current_folder(self)
	if row then
		self:set_folder_collapsed(not self.collapsed[row.section][row.path])
	end
end

---@param collapsed boolean
function Explorer:set_all_folders_collapsed(collapsed)
	if not self.options.grouped then
		return
	end

	local before = self.rows[current_row(self)]
	self.collapsed = { files = {}, reviewed = {} }
	if collapsed then
		local path = before and (before.path or before.file and before.file.path)
		local rows = build_rows(self)
		for _, row in ipairs(rows) do
			if row.path then
				self.collapsed[row.section][row.path] = true
				if path and row.section == before.section and path:sub(1, #row.path) == row.path then
					before = row
					path = nil
				end
			end
		end
	end

	render(self, before)
end

function Explorer:toggle_all_folders()
	local collapse = vim.iter(self.rows):any(function(row)
		return row.path ~= nil and not self.collapsed[row.section][row.path]
	end)
	self:set_all_folders_collapsed(collapse)
end

function Explorer:toggle_flatten_dirs()
	self.flatten_dirs = not self.flatten_dirs
	render(self)
end

function Explorer:activate()
	local row = self.rows[current_row(self)]
	if row and row.file then
		self.on_select(row.file, self.options.focus_on_select)
	else
		self:toggle_folder()
	end
end

function Explorer:toggle_view_mode()
	local file = self:current_file() or self.selected
	self.options.grouped = not self.options.grouped

	if file then
		expand_parents(self, file)
	end

	render(self, file and { file = file })
end

---@return integer|nil
function Explorer:toggle()
	if self.win then
		self.cursor_row = current_row(self)
		vim.api.nvim_win_close(self.win, true)
		return
	end

	local selected_row = self.rows[self.cursor_row]
	self.win = vim.api.nvim_open_win(self.buf, false, {
		split = "left",
		win = -1,
		width = width(self),
	})

	local options = vim.wo[self.win][0]
	options.winfixwidth = true
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.statuscolumn = ""
	options.winbar = ""
	options.winhighlight = ""
	options.foldcolumn = "0"
	options.fillchars = "eob: "
	options.wrap = false
	options.cursorline = true
	options.cursorcolumn = false
	options.foldenable = false
	options.diff = false
	options.scrollbind = false
	options.cursorbind = false
	options.colorcolumn = ""
	options.list = false
	options.spell = false

	render(self, selected_row)
	return self.win
end

function Explorer:resize()
	if self.win then
		vim.api.nvim_win_set_width(self.win, width(self))
	end
end

---@param opts {
--- files: AtlasDiffFile[],
--- options: AtlasPullsDiffExplorerConfig,
--- reviewed_files?: table<string, boolean>,
--- review_data?: PullsReviewData,
--- notes?: AtlasNote[],
--- on_select: fun(file: AtlasDiffFile, focus?: boolean),
---}
---@return AtlasDiffExplorer
function Explorer.new(opts)
	local options = opts.options
	local source = visible_files(opts.files, options.ignore)
	local annotations = collect_annotations(opts.review_data, opts.notes)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, string.format("Explorer [%d]", vim.api.nvim_get_current_tabpage()))
	local state = setmetatable({
		buf = buf,
		source = source,
		files = source,
		options = vim.deepcopy(options),
		rows = {},
		collapsed = { files = {}, reviewed = {} },
		flatten_dirs = true,
		reviewed_files = opts.reviewed_files,
		annotated_paths = annotations,
		on_select = opts.on_select,
		group = vim.api.nvim_create_augroup("AtlasDiffExplorer" .. buf, { clear = true }),
	}, Explorer)

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas-ui.diff-files"
	vim.bo[buf].modifiable = false

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = state.group,
		buffer = buf,
		-- Allow other autocmds to run here. Mainly needed for CodeDiff's BufReadCmd
		-- during cursor previews, otherwise added/deleted files stay empty.
		nested = true,
		callback = function()
			local row = current_row(state)
			if row == state.cursor_row then
				return
			end

			state.cursor_row = row
			local file = state:current_file()
			if state.options.preview and file and file ~= state.selected then
				state.on_select(file)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(event)
			if tonumber(event.match) == state.win then
				info.close(state.win)
				state.win = nil
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinResized", {
		group = state.group,
		callback = function()
			if state.win and vim.tbl_contains(vim.v.event.windows, state.win) then
				render(state)
			end
		end,
	})

	local opened, err = pcall(function()
		if options.hidden then
			render(state)
		else
			state:toggle()
		end
	end)
	if not opened then
		state:dispose()
		error(err, 0)
	end

	return state
end

function Explorer:dispose()
	if self.win then
		info.close(self.win)
	end

	vim.api.nvim_del_augroup_by_id(self.group)
	if vim.api.nvim_buf_is_valid(self.buf) then
		vim.api.nvim_buf_delete(self.buf, { force = true })
	end
	self.win = nil
end

return Explorer
