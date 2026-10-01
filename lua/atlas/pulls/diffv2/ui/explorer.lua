local icons = require("atlas.ui.shared.icons")
local info = require("atlas.ui.popups.info")
local utils = require("atlas.ui.shared.utils")
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diffv2.explorer")
local selection_namespace = vim.api.nvim_create_namespace("atlas.diffv2.explorer.selection")

local statuses = {
	added = { "A", "DiagnosticOk" },
	modified = { "M", "DiagnosticWarn" },
	deleted = { "D", "DiagnosticError" },
	renamed = { "R", "DiagnosticInfo" },
	copied = { "C", "DiagnosticInfo" },
	type_changed = { "T", "DiagnosticWarn" },
}

---@class AtlasDiffV2Explorer
---@field buf integer
---@field win integer|nil
---@field group integer
---@field files AtlasDiffV2File[] All files in navigation order, including collapsed descendants.
---@field source AtlasDiffV2File[]
---@field options AtlasPullsDiffExplorerConfig
---@field rows { file?: AtlasDiffV2File, path?: string, section?: string, header?: boolean, label?: string, prefix?: string }[]
---@field collapsed table<string, table<string, boolean>>
---@field reviewed_files table<string, boolean>|nil
---@field annotated_paths table<string, { comments?: boolean, notes?: boolean }>
---@field selected AtlasDiffV2File|nil
---@field cursor_row integer|nil
---@field on_select fun(file: AtlasDiffV2File, focus?: boolean)

---@param files AtlasDiffV2File[]
---@param ignore_patterns string[]|nil
---@return AtlasDiffV2File[]
local function filter(files, ignore_patterns)
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

---@param files AtlasDiffV2File[]
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

---@param state AtlasDiffV2Explorer
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
			while #child.files == 0 and vim.tbl_count(child.folders) == 1 do
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

---@param file AtlasDiffV2File
local function file_chunks(state, file, prefix, available)
	local name = file.path:match("[^/]+$") or file.path
	local icon, icon_hl = icons.pulls("file")
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
		local glyph = icons.general("comment")
		chunks[#chunks + 1] = { glyph .. " ", "AtlasLogInfo" }
	end
	if annotation and annotation.notes or previous_annotation and previous_annotation.notes then
		local glyph, highlight = icons.general("pin")
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
		local icon, highlight = icons.general(collapsed and "folder_closed" or "folder_open")
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

---@param file AtlasDiffV2File
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

---@param state AtlasDiffV2Explorer
---@param reviewed_files table<string, boolean>|nil
---@param review_data PullsReviewData|nil
---@param notes AtlasNote[]|nil
function M.update(state, reviewed_files, review_data, notes)
	state.reviewed_files = reviewed_files
	state.annotated_paths = collect_annotations(review_data, notes)
	render(state)
end

---@param state AtlasDiffV2Explorer
---@return AtlasDiffV2File|nil
function M.current_file(state)
	local row = state.rows[current_row(state)]
	return row and row.file
end

---@param state AtlasDiffV2Explorer
---@return integer|nil
function M.current_index(state)
	local current = state.selected
	if vim.api.nvim_get_current_win() == state.win then
		current = M.current_file(state) or current
	end

	for index, file in ipairs(state.files) do
		if file == current then
			return index
		end
	end
end

---@param state AtlasDiffV2Explorer
---@param file AtlasDiffV2File|nil
function M.reveal(state, file)
	file = vim.tbl_contains(state.files, file) and file or nil
	state.selected = file
	local row = highlight_selection(state)
	if not file then
		return
	end

	if not row then
		expand_parents(state, file)
		render(state, { file = file })
		return
	end

	state.cursor_row = row
	if state.win then
		vim.api.nvim_win_call(state.win, function()
			local view = vim.fn.winsaveview()
			view.lnum = row
			vim.fn.winrestview(view)
		end)
	end
end

---@param state AtlasDiffV2Explorer
function M.show_details(state)
	info.toggle({
		source_win = state.win,
		content = function(line)
			local row = state.rows[line]
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

---@param state AtlasDiffV2Explorer
function M.toggle_folder(state)
	local row = state.rows[current_row(state)]
	if row and row.file then
		local parent = row.file.path:match("^.*/")
		row = vim.iter(state.rows):find(function(item)
			return item.path ~= nil and item.path == parent and item.section == row.section
		end)
	end

	if not row or not row.path then
		return
	end

	local collapsed = state.collapsed[row.section]
	collapsed[row.path] = not collapsed[row.path] or nil
	render(state, row)
end

---@param state AtlasDiffV2Explorer
function M.toggle_all_folders(state)
	if not state.options.grouped then
		return
	end

	local before = state.rows[current_row(state)]
	local collapse = vim.iter(state.rows):any(function(row)
		return row.path ~= nil and not state.collapsed[row.section][row.path]
	end)

	state.collapsed = { files = {}, reviewed = {} }
	if collapse then
		local path = before and (before.path or before.file and before.file.path)
		local rows = build_rows(state)
		for _, row in ipairs(rows) do
			if row.path then
				state.collapsed[row.section][row.path] = true
				if path and row.section == before.section and path:sub(1, #row.path) == row.path then
					before = row
					path = nil
				end
			end
		end
	end

	render(state, before)
end

function M.activate(state)
	local row = state.rows[current_row(state)]
	if row and row.file then
		state.on_select(row.file, state.options.focus_on_select)
	else
		M.toggle_folder(state)
	end
end

function M.toggle_view_mode(state)
	local file = M.current_file(state) or state.selected
	state.options.grouped = not state.options.grouped

	if file then
		expand_parents(state, file)
	end

	render(state, file and { file = file })
end

---@param state AtlasDiffV2Explorer
---@return integer|nil
function M.toggle(state)
	if state.win then
		state.cursor_row = current_row(state)
		vim.api.nvim_win_close(state.win, true)
		return
	end

	local selected_row = state.rows[state.cursor_row]
	state.win = vim.api.nvim_open_win(state.buf, false, {
		split = "left",
		win = -1,
		width = width(state),
	})

	local options = vim.wo[state.win][0]
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

	render(state, selected_row)
	return state.win
end

---@param state AtlasDiffV2Explorer
function M.resize(state)
	if state.win then
		vim.api.nvim_win_set_width(state.win, width(state))
	end
end

---@param opts {
--- files: AtlasDiffV2File[],
--- options: AtlasPullsDiffExplorerConfig,
--- reviewed_files?: table<string, boolean>,
--- review_data?: PullsReviewData,
--- notes?: AtlasNote[],
--- on_select: fun(file: AtlasDiffV2File, focus?: boolean),
---}
---@return AtlasDiffV2Explorer
function M.create(opts)
	local options = opts.options
	local source = filter(opts.files, options.ignore)
	table.sort(source, function(a, b)
		return a.path < b.path
	end)
	local annotations = collect_annotations(opts.review_data, opts.notes)

	local buf = vim.api.nvim_create_buf(false, true)
	local state = {
		buf = buf,
		source = source,
		files = source,
		options = vim.deepcopy(options),
		rows = {},
		collapsed = { files = {}, reviewed = {} },
		reviewed_files = opts.reviewed_files,
		annotated_paths = annotations,
		on_select = opts.on_select,
		group = vim.api.nvim_create_augroup("AtlasDiffV2Explorer" .. buf, { clear = true }),
	}

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas.diff-files"
	vim.bo[buf].syntax = "OFF"
	vim.bo[buf].modifiable = false

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = state.group,
		buffer = buf,
		callback = function()
			local row = current_row(state)
			if row == state.cursor_row then
				return
			end

			state.cursor_row = row
			local file = M.current_file(state)
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
			M.toggle(state)
		end
	end)
	if not opened then
		M.dispose(state)
		error(err, 0)
	end

	return state
end

function M.dispose(state)
	if state.win then
		info.close(state.win)
	end

	vim.api.nvim_del_augroup_by_id(state.group)
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
	state.win = nil
end

return M
