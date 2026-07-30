local M = {}

local diff = require("atlas.ui.components.diff_hunks")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_native_diff_panel")

local STATUS_MARKERS = {
	added = { "A", "DiagnosticOk" },
	modified = { "M", "DiagnosticWarn" },
	deleted = { "D", "DiagnosticError" },
	renamed = { "R", "DiagnosticInfo" },
	type_changed = { "T", "DiagnosticWarn" },
	unknown = { "?", "AtlasTextMuted" },
}

local comment_icon, comment_icon_hl = icons.general("comment")
local note_icon, note_icon_hl = icons.general("pin")
local folder_closed_icon, folder_closed_icon_hl = icons.general("folder_closed")
local folder_open_icon, folder_open_icon_hl = icons.general("folder_open")

---@class AtlasDiffExplorerOptions
---@field grouped boolean
---@field hidden boolean
---@field show_commits boolean
---@field width integer
---@field initial_focus "explorer"|"diff"
---@field ignore string[]

---@return AtlasDiffExplorerOptions
function M.options()
	local diff_config = (require("atlas.config").options.pulls or {}).diff or {}
	local config = diff_config.explorer or {}
	return {
		grouped = config.grouped == true,
		hidden = config.hidden == true,
		show_commits = config.show_commits ~= false,
		width = math.max(20, math.floor(tonumber(config.width) or 40)),
		initial_focus = config.initial_focus == "diff" and "diff" or "explorer",
		ignore = config.ignore or {},
	}
end

---@param files DiffFile[]
---@param options AtlasDiffExplorerOptions
---@return DiffFile[]
function M.filter(files, options)
	if #options.ignore == 0 then
		return files
	end
	local patterns = {}
	for _, pattern in ipairs(options.ignore) do
		local ok, regex = pcall(vim.fn.glob2regpat, pattern)
		if ok then
			table.insert(patterns, regex)
		end
	end
	return vim.tbl_filter(function(file)
		for _, pattern in ipairs(patterns) do
			if vim.fn.match(file.path, pattern) >= 0 then
				return false
			end
		end
		return true
	end, files)
end

---@param author { name: string, nickname: string|nil }|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.nickname and author.nickname ~= "" then
		return author.nickname
	end
	return author.name ~= "" and author.name or "Unknown"
end

---@param task PullsComment
---@param plural boolean
---@return string
local function task_label(task, plural)
	local label = task.task_label or "Task"
	return plural and (label .. "s") or label
end

---@param status DiffFileStatus
---@return string, string
local function status_marker(status)
	local marker = STATUS_MARKERS[status] or STATUS_MARKERS.unknown
	return marker[1], marker[2]
end

---@param path string
---@return string|nil
local function directory(path)
	return path:match("^(.*)/[^/]+$")
end

---@param path string
---@return string
local function basename(path)
	return path:match("([^/]+)$") or path
end

---@param file DiffFile
---@return string
local function file_label(file)
	local name = basename(file.path)
	if file.status ~= "renamed" or not file.old_path then
		return name
	end
	local old_name = basename(file.old_path)
	return old_name ~= name and (old_name .. " -> " .. name) or name
end

---@param filename string
---@return string|nil, string|nil
local function web_icon(filename)
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")
	if not has_devicons then
		return nil, nil
	end
	local icon, highlight = devicons.get_icon(filename, nil, { default = true })
	if icon == nil or icon == "" then
		return nil, nil
	end
	return icon, highlight
end

---@param file DiffFile
---@return { text: string, hl_group: string }[]
local function stat_parts(file)
	local additions, deletions = diff.file_stats(file)
	local parts = {}
	if additions > 0 then
		table.insert(parts, { text = "+" .. additions, hl_group = "AtlasTextPositive" })
	end
	if deletions > 0 then
		table.insert(parts, { text = "-" .. deletions, hl_group = "AtlasLogError" })
	end
	return parts
end

---@param session AtlasNativeDiffSession
---@return integer[], integer[]
local function grouped_indices(session)
	local unreviewed, reviewed = {}, {}
	for index, file in ipairs(session.files) do
		table.insert(session.reviewed_files[file.path] and reviewed or unreviewed, index)
	end
	return unreviewed, reviewed
end

---@param session AtlasNativeDiffSession
---@return integer[]
function M.ordered_indices(session)
	local unreviewed, reviewed = grouped_indices(session)
	vim.list_extend(unreviewed, reviewed)
	return unreviewed
end

---@param session AtlasNativeDiffSession
---@param file_index integer
function M.reveal_file(session, file_index)
	local file = session.files[file_index]
	local parent = file and directory(file.path) or nil
	if parent then
		session.collapsed_folders[parent] = nil
	end
end

---@param session AtlasNativeDiffSession
---@return integer
function M.width(session)
	return math.min(session.explorer.width, math.max(20, vim.o.columns - 40))
end

---@param session AtlasNativeDiffSession
---@param win integer|nil
function M.configure_window(session, win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local options = vim.wo[win][0]
	options.cursorline = true
	options.colorcolumn = ""
	options.cursorbind = false
	options.cursorcolumn = false
	options.diff = false
	options.foldenable = false
	options.foldcolumn = "0"
	options.list = false
	options.number = false
	options.relativenumber = false
	options.scrollbind = false
	options.signcolumn = "no"
	options.spell = false
	options.statuscolumn = ""
	options.statusline = " "
	options.winhighlight = ""
	options.winfixwidth = true
	options.wrap = false
	options.winbar = ""
	vim.api.nvim_win_set_width(win, M.width(session))
end

---@param session AtlasNativeDiffSession
function M.configure(session)
	M.configure_window(session, session.panel.win)
	M.configure_window(session, session.commits_panel.win)
end

---@alias AtlasDiffExplorerVirtualLine { [1]: string, [2]: string }[]

---@param session AtlasNativeDiffSession
---@param lines string[]
---@param highlights { [1]: integer, [2]: integer, [3]: integer, [4]: string }[]
---@param headers table<integer, AtlasDiffExplorerVirtualLine[]>
---@param first_header AtlasDiffExplorerVirtualLine
local function write(session, lines, highlights, headers, first_header)
	local buf = session.panel.buf
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, namespace, highlight[1], highlight[2], {
			end_col = highlight[3],
			hl_group = highlight[4],
		})
	end
	vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
		virt_text = first_header,
		virt_text_pos = "overlay",
	})
	local line_count = vim.api.nvim_buf_line_count(buf)
	for row, virtual_lines in pairs(headers) do
		local above = #lines == 0 or row < #lines
		vim.api.nvim_buf_set_extmark(buf, namespace, above and row or line_count - 1, 0, {
			virt_lines = virtual_lines,
			virt_lines_above = above,
		})
	end
end

---@param session AtlasNativeDiffSession
---@param annotated_paths? table<string, boolean>
function M.render(session, annotated_paths)
	local buf = session.panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local width = session.panel.win
			and vim.api.nvim_win_is_valid(session.panel.win)
			and vim.api.nvim_win_get_width(session.panel.win)
		or M.width(session)
	-- Keep the first extmark heading visible at the top.
	local lines, highlights, headers = { "" }, {}, {}
	local first_header
	session.panel_items = {}

	local unreviewed, reviewed = grouped_indices(session)
	annotated_paths = annotated_paths or {}
	local noted_paths = {}
	for _, note in ipairs((session.notes and session.notes.items) or {}) do
		noted_paths[note.file_path] = true
	end
	---@param text string
	---@param spacing boolean|nil
	local function add_header(text, spacing)
		if not first_header then
			first_header = { { text, "AtlasLogInfo" } }
			return
		end
		local row = #lines
		local virtual_lines = headers[row] or {}
		if spacing then
			table.insert(virtual_lines, { { " ", "Normal" } })
		end
		table.insert(virtual_lines, { { text, "AtlasLogInfo" } })
		headers[row] = virtual_lines
	end

	---@param file_index integer
	---@param indent integer
	---@param show_directory boolean
	local function add_file(file_index, indent, show_directory)
		local file = session.files[file_index]
		local label = file_label(file)
		local parent = directory(file.path)
		local status, status_highlight = status_marker(file.status)
		local has_comments = annotated_paths[file.path] or (file.old_path and annotated_paths[file.old_path])
		local has_notes = file.status ~= "deleted" and noted_paths[file.path]
		local devicon, devicon_hl = web_icon(basename(file.path))
		local stats = stat_parts(file)
		local stats_texts = {}
		for _, part in ipairs(stats) do
			table.insert(stats_texts, part.text)
		end
		local suffix = table.concat(stats_texts, " ")

		local prefix_parts = {}
		if has_comments then
			table.insert(prefix_parts, { text = comment_icon, hl_group = comment_icon_hl })
		end
		if has_notes then
			table.insert(prefix_parts, { text = note_icon, hl_group = note_icon_hl })
		end
		table.insert(prefix_parts, { text = status, hl_group = status_highlight })
		if devicon then
			table.insert(prefix_parts, { text = devicon, hl_group = devicon_hl or "AtlasTextMuted" })
		end
		local prefix_texts = {}
		for _, part in ipairs(prefix_parts) do
			table.insert(prefix_texts, part.text)
		end
		local prefix = table.concat(prefix_texts, " ") .. " "
		local suffix_width = suffix ~= "" and vim.fn.strdisplaywidth(suffix) + 1 or 0
		local content_width = math.max(1, width - indent - vim.fn.strdisplaywidth(prefix) - suffix_width - 1)
		local display_label = utils.truncate(label, content_width)
		local path_width = content_width - vim.fn.strdisplaywidth(display_label) - 1
		local display_path = show_directory and parent and path_width > 2 and utils.truncate(parent .. "/", path_width)
			or ""
		local content = display_label .. (display_path ~= "" and " " .. display_path or "")
		local left = string.rep(" ", indent) .. prefix .. content
		local padding = suffix ~= ""
				and math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(suffix) - 1)
			or 0
		local text = left .. string.rep(" ", padding) .. suffix
		table.insert(lines, text)
		local line = #lines
		session.panel_items[line] = { kind = "file", index = file_index }

		local col = indent
		for _, part in ipairs(prefix_parts) do
			table.insert(highlights, { line - 1, col, col + #part.text, part.hl_group })
			col = col + #part.text + 1
		end
		table.insert(highlights, { line - 1, col, col + #display_label, "Normal" })
		if display_path ~= "" then
			local path_start = col + #display_label + 1
			table.insert(highlights, { line - 1, path_start, path_start + #display_path, "AtlasTextMuted" })
		end
		local stat_col = #left + padding
		for _, part in ipairs(stats) do
			table.insert(highlights, { line - 1, stat_col, stat_col + #part.text, part.hl_group })
			stat_col = stat_col + #part.text + 1
		end
	end

	---@param parent string
	local function add_folder(parent)
		local collapsed = session.collapsed_folders[parent] == true
		local icon = collapsed and folder_closed_icon or folder_open_icon
		local icon_hl = collapsed and folder_closed_icon_hl or folder_open_icon_hl
		local prefix = icon .. " "
		local label = utils.truncate(parent .. "/", math.max(1, width - vim.fn.strdisplaywidth(prefix)))
		local text = prefix .. label
		table.insert(lines, text)
		session.panel_items[#lines] = { kind = "folder", path = parent }
		table.insert(highlights, { #lines - 1, 0, #icon, icon_hl })
		table.insert(highlights, { #lines - 1, #prefix, #text, "AtlasLogInfo" })
	end

	---@param title string
	---@param indices integer[]
	---@param spacing boolean|nil
	local function add_section(title, indices, spacing)
		add_header(string.format("%s (%d)", title, #indices), spacing)
		if not session.explorer.grouped then
			for _, index in ipairs(indices) do
				add_file(index, 2, true)
			end
			return
		end
		local active_directory
		for _, index in ipairs(indices) do
			local parent = directory(session.files[index].path)
			if parent ~= active_directory then
				active_directory = parent
				if parent then
					add_folder(parent)
				end
			end
			if not parent or not session.collapsed_folders[parent] then
				add_file(index, 2, false)
			end
		end
	end

	add_section("Files", unreviewed)
	if session.review_context or #reviewed > 0 then
		add_section("Reviewed", reviewed, true)
	end

	local tasks = (session.review and session.review.tasks) or {}
	if #tasks > 0 then
		add_header(string.format("%s (%d)", task_label(tasks[1], true), #tasks), true)
		for _, task in ipairs(tasks) do
			local checkbox = task.state == "RESOLVED" and "[x]" or "[ ]"
			local content = utils.task_text(task.content_display or task.content_raw):match("[^\n]*") or ""
			if content == "" then
				content = string.format("(empty %s)", task_label(task, false):lower())
			end
			local text = checkbox .. " " .. utils.truncate(content, math.max(1, width - #checkbox - 1))
			table.insert(lines, text)
			session.panel_items[#lines] = { kind = "task", comment = task }
			table.insert(highlights, {
				#lines - 1,
				0,
				#checkbox,
				task.state == "RESOLVED" and "AtlasTextPositive" or "AtlasTextMuted",
			})
		end
	end

	write(session, lines, highlights, headers, first_header)
	local selected_line = M.line_for_file(session, session.pending_index or session.selected_index)
	if selected_line then
		vim.api.nvim_buf_set_extmark(buf, namespace, selected_line - 1, 0, {
			line_hl_group = "Visual",
			priority = 10,
		})
		if session.panel.win and vim.api.nvim_win_is_valid(session.panel.win) then
			local cursor = vim.api.nvim_win_get_cursor(session.panel.win)
			if cursor[1] == 1 then
				vim.api.nvim_win_set_cursor(session.panel.win, { selected_line, 0 })
			end
		end
	end
end

---@param session AtlasNativeDiffSession
---@return { kind: "file", index: integer }|{ kind: "folder", path: string }|{ kind: "task", comment: PullsComment }|nil
local function item_at_cursor(session)
	if vim.api.nvim_get_current_buf() ~= session.panel.buf then
		return nil
	end
	return session.panel_items[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param session AtlasNativeDiffSession
---@return integer|nil
function M.file_at_cursor(session)
	local item = item_at_cursor(session)
	return item and item.kind == "file" and item.index or nil
end

---@param session AtlasNativeDiffSession
---@return PullsComment|nil
function M.task_at_cursor(session)
	local item = item_at_cursor(session)
	return item and item.kind == "task" and item.comment or nil
end

---@param session AtlasNativeDiffSession
---@param item AtlasNativeDiffPanelItem|nil
---@return boolean
local function toggle_folder(session, item)
	if not item or item.kind ~= "folder" then
		return false
	end
	session.collapsed_folders[item.path] = not session.collapsed_folders[item.path]
	session.refresh_ui()
	return true
end

---@param session AtlasNativeDiffSession
---@return integer|nil
function M.open_at_cursor(session)
	local item = item_at_cursor(session)
	if not item then
		return nil
	end
	if item.kind == "folder" then
		toggle_folder(session, item)
		return nil
	end
	return item.kind == "file" and item.index or nil
end

---@param session AtlasNativeDiffSession
---@return boolean
function M.toggle_folder(session)
	return toggle_folder(session, item_at_cursor(session))
end

---@param session AtlasNativeDiffSession
---@return boolean
function M.toggle_all_folders(session)
	if not session.explorer.grouped then
		return false
	end
	local folders = {}
	for _, file in ipairs(session.files) do
		local parent = directory(file.path)
		if parent then
			folders[parent] = true
		end
	end
	if next(folders) == nil then
		return false
	end
	local collapse = false
	for parent in pairs(folders) do
		if not session.collapsed_folders[parent] then
			collapse = true
			break
		end
	end
	for parent in pairs(folders) do
		session.collapsed_folders[parent] = collapse or nil
	end
	session.refresh_ui()
	return true
end

---@param session AtlasNativeDiffSession
---@param file_index integer
---@return integer|nil
function M.line_for_file(session, file_index)
	for line, item in pairs(session.panel_items) do
		if item.kind == "file" and item.index == file_index then
			return line
		end
	end
	return nil
end

---@param session AtlasNativeDiffSession
function M.show_path(session)
	local item = item_at_cursor(session)
	if not item then
		return
	end
	if item.kind == "task" then
		local task = item.comment
		local content = utils.task_text(task.content_display or task.content_raw)
		local empty = string.format("(empty %s)", task_label(task, false):lower())
		local lines = vim.split(content ~= "" and content or empty, "\n", { plain = true })
		table.insert(lines, "")
		table.insert(lines, string.format("by @%s  %s", author_name(task.author), utils.relative_time(task.created_on)))
		local width = math.max(1, math.min(100, vim.o.columns - 4))
		vim.lsp.util.open_floating_preview(lines, "markdown", {
			border = "rounded",
			focusable = false,
			max_width = width,
			wrap_at = width,
			title = string.format(" %s ", task_label(task, false)),
		})
		return
	end

	local path
	if item.kind == "folder" then
		path = vim.fs.joinpath(session.range.root, item.path)
	else
		local file = session.files[item.index]
		if not file then
			return
		end
		path = vim.fs.joinpath(session.range.root, file.path)
		if file.status == "renamed" and file.old_path then
			path = vim.fs.joinpath(session.range.root, file.old_path) .. " -> " .. path
		end
	end
	local width = math.max(1, math.min(100, vim.o.columns - 4))
	vim.lsp.util.open_floating_preview({ path }, "text", {
		border = "rounded",
		focusable = false,
		max_width = width,
		wrap_at = width,
		title = " Path ",
	})
end

return M
