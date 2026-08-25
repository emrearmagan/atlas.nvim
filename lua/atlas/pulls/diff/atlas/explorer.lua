local M = {}

local config = require("atlas.config")
local diff = require("atlas.ui.components.diff_hunks")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_native_panel")

local STATUS_MARKERS = {
	added = { "A", "DiagnosticOk" },
	modified = { "M", "DiagnosticWarn" },
	deleted = { "D", "DiagnosticError" },
	renamed = { "R", "DiagnosticInfo" },
	type_changed = { "T", "DiagnosticWarn" },
	unknown = { "?", "AtlasTextMuted" },
}

local comment_icon = icons.general("comment")
local note_icon, note_icon_hl = icons.general("pin")
local folder_closed_icon, folder_closed_icon_hl = icons.general("folder_closed")
local folder_open_icon, folder_open_icon_hl = icons.general("folder_open")

---@class AtlasNativeDiffExplorerOptions
---@field grouped boolean
---@field hidden boolean
---@field show_commits boolean
---@field width integer
---@field initial_focus "explorer"|"diff"
---@field preview boolean
---@field ignore string[]

---@alias AtlasNativeDiffPanelItem
---| { kind: "file", index: integer }
---| { kind: "folder", path: string }

---@return AtlasNativeDiffExplorerOptions
function M.options()
	local diff_config = (config.options.pulls or {}).diff or {}
	local explorer_config = diff_config.explorer or {}
	return {
		grouped = explorer_config.grouped == true,
		hidden = explorer_config.hidden == true,
		show_commits = explorer_config.show_commits == true,
		width = math.max(20, math.floor(tonumber(explorer_config.width) or 40)),
		initial_focus = explorer_config.initial_focus == "diff" and "diff" or "explorer",
		preview = explorer_config.preview == true,
		ignore = explorer_config.ignore or {},
	}
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

---@class AtlasNativeDiffExplorerTree
---@field name string
---@field path string
---@field folders table<string, AtlasNativeDiffExplorerTree>
---@field files integer[]

---@param files DiffFile[]
---@param indices integer[]
---@return AtlasNativeDiffExplorerTree
local function build_tree(files, indices)
	local root = { name = "", path = "", folders = {}, files = {} }
	for _, index in ipairs(indices) do
		local parts = vim.split(files[index].path, "/", { plain = true })
		local node = root
		for part_index = 1, #parts - 1 do
			local name = parts[part_index]
			if not node.folders[name] then
				local path = node.path == "" and name or (node.path .. "/" .. name)
				node.folders[name] = { name = name, path = path, folders = {}, files = {} }
			end
			node = node.folders[name]
		end
		table.insert(node.files, index)
	end
	return root
end

---@param node AtlasNativeDiffExplorerTree
---@return AtlasNativeDiffExplorerTree[]
local function sorted_folders(node)
	local folders = {}
	for _, folder in pairs(node.folders) do
		table.insert(folders, folder)
	end
	table.sort(folders, function(left, right)
		return left.name < right.name
	end)
	return folders
end

---@param node AtlasNativeDiffExplorerTree
---@param files DiffFile[]
---@return integer[]
local function sorted_files(node, files)
	local indices = {}
	for _, index in ipairs(node.files) do
		table.insert(indices, index)
	end
	table.sort(indices, function(left, right)
		return files[left].path < files[right].path
	end)
	return indices
end

---@param node AtlasNativeDiffExplorerTree
---@return AtlasNativeDiffExplorerTree node, string label
local function compact_folder(node)
	local label = node.name
	while #node.files == 0 do
		local folders = sorted_folders(node)
		if #folders ~= 1 then
			break
		end
		node = folders[1]
		label = label .. "/" .. node.name
	end
	return node, label
end

---@param files DiffFile[]
---@param reviewed_files table<string, boolean>
---@return integer[], integer[]
local function split_indices(files, reviewed_files)
	local unreviewed, reviewed = {}, {}
	for index, file in ipairs(files) do
		table.insert(reviewed_files[file.path] and reviewed or unreviewed, index)
	end
	return unreviewed, reviewed
end

---@param files DiffFile[]
---@param grouped boolean
---@param reviewed_files table<string, boolean>
---@return integer[]
local function ordered_indices(files, grouped, reviewed_files)
	local unreviewed, reviewed = split_indices(files, reviewed_files)
	if not grouped then
		vim.list_extend(unreviewed, reviewed)
		return unreviewed
	end
	local ordered = {}
	local function append(node)
		for _, folder in ipairs(sorted_folders(node)) do
			append(folder)
		end
		vim.list_extend(ordered, sorted_files(node, files))
	end
	append(build_tree(files, unreviewed))
	append(build_tree(files, reviewed))
	return ordered
end

---@param session AtlasDiffSession
---@return integer[], integer[]
local function grouped_indices(session)
	return split_indices(session.viewer_state.files, session.reviewed_files)
end

---@param session AtlasDiffSession
---@return integer[]
function M.ordered_indices(session)
	return ordered_indices(session.viewer_state.files, session.viewer_state.explorer.grouped, session.reviewed_files)
end

---@param files DiffFile[]
---@param options AtlasNativeDiffExplorerOptions
---@return DiffFile[]
function M.filter(files, options)
	local patterns = {}
	for _, pattern in ipairs(options.ignore) do
		local ok, regex = pcall(vim.fn.glob2regpat, pattern)
		if ok then
			table.insert(patterns, regex)
		end
	end
	local visible = vim.tbl_filter(function(file)
		for _, pattern in ipairs(patterns) do
			if vim.fn.match(file.path, pattern) >= 0 then
				return false
			end
		end
		return true
	end, files)
	local result = {}
	for _, index in ipairs(ordered_indices(visible, options.grouped, {})) do
		table.insert(result, visible[index])
	end
	return result
end

---@param session AtlasDiffSession
---@param file_index integer
function M.reveal_file(session, file_index)
	local file = session.viewer_state.files[file_index]
	local parent = file and directory(file.path) or nil
	while parent do
		session.viewer_state.collapsed_folders[parent] = nil
		parent = directory(parent)
	end
end

---@param session AtlasDiffSession
---@return integer
function M.width(session)
	return math.min(session.viewer_state.explorer.width, math.max(20, vim.o.columns - 40))
end

---@param win integer|nil
function M.configure_window(win)
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
	options.winhighlight = ""
	options.winfixwidth = true
	options.wrap = false
	options.winbar = ""
end

---@param session AtlasDiffSession
function M.configure(session)
	M.configure_window(session.viewer_state.panel.win)
	M.configure_window(session.viewer_state.commits_panel.win)
end

---@alias AtlasNativeDiffExplorerVirtualLine { [1]: string, [2]: string }[]

---@param session AtlasDiffSession
---@param lines string[]
---@param highlights { [1]: integer, [2]: integer, [3]: integer, [4]: string }[]
---@param headers table<integer, AtlasNativeDiffExplorerVirtualLine[]>
---@param first_header AtlasNativeDiffExplorerVirtualLine
local function write(session, lines, highlights, headers, first_header)
	local buf = session.viewer_state.panel.buf
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

---@param session AtlasDiffSession
---@param annotated_paths? table<string, { comments: boolean, notes: boolean }>
function M.render(session, annotated_paths)
	local buf = session.viewer_state.panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local width = session.viewer_state.panel.win
			and vim.api.nvim_win_is_valid(session.viewer_state.panel.win)
			and vim.api.nvim_win_get_width(session.viewer_state.panel.win)
		or M.width(session)
	local unreviewed, reviewed = grouped_indices(session)
	-- Keep the first extmark heading visible at the top.
	local lines, highlights, headers = { "" }, {}, {}
	local first_header = { { string.format("Files (%d)", #unreviewed), "AtlasLogInfo" } }
	session.viewer_state.panel_items = {}

	annotated_paths = annotated_paths or {}
	---@param text string
	---@param spacing boolean|nil
	local function add_header(text, spacing)
		local row = #lines
		local virtual_lines = headers[row] or {}
		if spacing then
			table.insert(virtual_lines, { { " ", "Normal" } })
		end
		table.insert(virtual_lines, { { text, "AtlasLogInfo" } })
		headers[row] = virtual_lines
	end

	---@param file_index integer
	---@param branch string
	---@param show_directory boolean
	local function add_file(file_index, branch, show_directory)
		local file = session.viewer_state.files[file_index]
		local label = file_label(file)
		local parent = directory(file.path)
		local status, status_highlight = status_marker(file.status)
		local annotation = annotated_paths[file.path]
		local old_annotation = file.old_path and annotated_paths[file.old_path]
		local has_comments = (annotation and annotation.comments) or (old_annotation and old_annotation.comments)
		local has_notes = file.status ~= "deleted"
			and ((annotation and annotation.notes) or (old_annotation and old_annotation.notes))
		local devicon, devicon_hl = web_icon(basename(file.path))
		local status_part = { text = status, hl_group = status_highlight }
		local suffix_parts = stat_parts(file)
		table.insert(suffix_parts, status_part)
		local suffix_texts = {}
		for _, part in ipairs(suffix_parts) do
			table.insert(suffix_texts, part.text)
		end
		local suffix = table.concat(suffix_texts, " ")

		local prefix_parts = {}
		if has_comments then
			table.insert(prefix_parts, { text = comment_icon, hl_group = "AtlasLogInfo" })
		end
		if has_notes then
			table.insert(prefix_parts, { text = note_icon, hl_group = note_icon_hl })
		end
		if devicon then
			table.insert(prefix_parts, { text = devicon, hl_group = devicon_hl or "AtlasTextMuted" })
		end
		local prefix_texts = {}
		for _, part in ipairs(prefix_parts) do
			table.insert(prefix_texts, part.text)
		end
		local prefix = #prefix_texts > 0 and (table.concat(prefix_texts, " ") .. " ") or ""
		local available = math.max(1, width - vim.fn.strdisplaywidth(branch) - vim.fn.strdisplaywidth(prefix) - 1)
		if vim.fn.strdisplaywidth(label .. " " .. suffix) > available then
			suffix_parts = { status_part }
			suffix = status
		end
		if vim.fn.strdisplaywidth(label .. " " .. suffix) > available then
			suffix_parts = {}
			suffix = ""
		end
		local suffix_width = suffix ~= "" and vim.fn.strdisplaywidth(suffix) + 1 or 0
		local content_width = math.max(1, available - suffix_width)
		local display_label = utils.truncate(label, content_width)
		local path_width = content_width - vim.fn.strdisplaywidth(display_label) - 1
		local display_path = show_directory and parent and path_width > 2 and utils.truncate(parent .. "/", path_width)
			or ""
		local content = display_label .. (display_path ~= "" and " " .. display_path or "")
		local left = branch .. prefix .. content
		local padding = suffix ~= ""
				and math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(suffix) - 1)
			or 0
		local text = left .. string.rep(" ", padding) .. suffix
		table.insert(lines, text)
		local line = #lines
		session.viewer_state.panel_items[line] = { kind = "file", index = file_index }

		table.insert(highlights, { line - 1, 0, #branch, "AtlasTextMuted" })
		local col = #branch
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
		for _, part in ipairs(suffix_parts) do
			table.insert(highlights, { line - 1, stat_col, stat_col + #part.text, part.hl_group })
			stat_col = stat_col + #part.text + 1
		end
	end

	---@param node AtlasNativeDiffExplorerTree
	---@param label string
	---@param branch string
	---@return boolean collapsed
	local function add_folder(node, label, branch)
		local collapsed = session.viewer_state.collapsed_folders[node.path] == true
		local icon = collapsed and folder_closed_icon or folder_open_icon
		local icon_hl = collapsed and folder_closed_icon_hl or folder_open_icon_hl
		local available = width - vim.fn.strdisplaywidth(branch) - vim.fn.strdisplaywidth(icon) - 1
		label = utils.truncate(label, math.max(1, available))
		local text = branch .. icon .. " " .. label
		table.insert(lines, text)
		session.viewer_state.panel_items[#lines] = { kind = "folder", path = node.path }
		table.insert(highlights, { #lines - 1, 0, #branch, "AtlasTextMuted" })
		local icon_start = #branch
		table.insert(highlights, { #lines - 1, icon_start, icon_start + #icon, icon_hl })
		local label_start = icon_start + #icon + 1
		table.insert(highlights, { #lines - 1, label_start, #text, "AtlasLogInfo" })
		return collapsed
	end

	---@param indices integer[]
	local function add_section(indices)
		if not session.viewer_state.explorer.grouped then
			for _, index in ipairs(indices) do
				add_file(index, "  ", true)
			end
			return
		end

		local function add_tree(node, prefix)
			local folders = sorted_folders(node)
			local files = sorted_files(node, session.viewer_state.files)
			local total = #folders + #files
			local entry = 0
			for _, folder in ipairs(folders) do
				entry = entry + 1
				local displayed, label = compact_folder(folder)
				local last = entry == total
				local collapsed = add_folder(displayed, label, prefix .. (last and "└ " or "├ "))
				if not collapsed then
					add_tree(displayed, prefix .. (last and "  " or "│ "))
				end
			end
			for _, index in ipairs(files) do
				entry = entry + 1
				add_file(index, prefix .. (entry == total and "└ " or "├ "), false)
			end
		end
		add_tree(build_tree(session.viewer_state.files, indices), "")
	end

	add_section(unreviewed)
	if session.review or #reviewed > 0 then
		add_header(string.format("Reviewed (%d)", #reviewed), true)
		add_section(reviewed)
	end

	write(session, lines, highlights, headers, first_header)
end

---@param session AtlasDiffSession
---@return { kind: "file", index: integer }|{ kind: "folder", path: string }|nil
local function item_at_cursor(session)
	if vim.api.nvim_get_current_buf() ~= session.viewer_state.panel.buf then
		return nil
	end
	return session.viewer_state.panel_items[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param session AtlasDiffSession
---@return integer|nil
function M.file_at_cursor(session)
	local item = item_at_cursor(session)
	return item and item.kind == "file" and item.index or nil
end

---@param session AtlasDiffSession
---@param group integer
---@param on_move fun(index: integer)
function M.attach(session, group, on_move)
	if not session.viewer_state.explorer.preview then
		return
	end
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = session.viewer_state.panel.buf,
		callback = function()
			local index = M.file_at_cursor(session)
			if index then
				on_move(index)
			end
		end,
	})
end

---@param session AtlasDiffSession
---@param item AtlasNativeDiffPanelItem|nil
---@return boolean
local function toggle_folder(session, item)
	if not item or item.kind ~= "folder" then
		return false
	end
	session.viewer_state.collapsed_folders[item.path] = not session.viewer_state.collapsed_folders[item.path]
	M.render(session, session.viewer_state.annotated_paths)
	return true
end

---@param session AtlasDiffSession
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

---@param session AtlasDiffSession
---@return boolean
function M.toggle_folder(session)
	return toggle_folder(session, item_at_cursor(session))
end

---@param session AtlasDiffSession
---@return boolean grouped
function M.toggle_grouping(session)
	local file_index = M.file_at_cursor(session)
		or session.viewer_state.pending_index
		or session.viewer_state.selected_index
	session.viewer_state.explorer.grouped = not session.viewer_state.explorer.grouped
	M.render(session, session.viewer_state.annotated_paths)

	local line = M.line_for_file(session, file_index)
	if line and session.viewer_state.panel.win and vim.api.nvim_win_is_valid(session.viewer_state.panel.win) then
		vim.api.nvim_win_set_cursor(session.viewer_state.panel.win, { line, 0 })
	end
	return session.viewer_state.explorer.grouped
end

---@param session AtlasDiffSession
---@return boolean
function M.toggle_all_folders(session)
	if not session.viewer_state.explorer.grouped then
		return false
	end
	local folders = {}
	for _, file in ipairs(session.viewer_state.files) do
		local parent = directory(file.path)
		while parent do
			folders[parent] = true
			parent = directory(parent)
		end
	end
	if next(folders) == nil then
		return false
	end
	local collapse = false
	for _, item in pairs(session.viewer_state.panel_items) do
		if item.kind == "folder" and not session.viewer_state.collapsed_folders[item.path] then
			collapse = true
			break
		end
	end
	for parent in pairs(folders) do
		session.viewer_state.collapsed_folders[parent] = collapse or nil
	end
	M.render(session, session.viewer_state.annotated_paths)
	return true
end

---@param session AtlasDiffSession
---@param file_index integer
---@return integer|nil
function M.line_for_file(session, file_index)
	for line, item in pairs(session.viewer_state.panel_items) do
		if item.kind == "file" and item.index == file_index then
			return line
		end
	end
	return nil
end

---@param session AtlasDiffSession
function M.show_path(session)
	local item = item_at_cursor(session)
	if not item then
		return
	end

	local path = item.kind == "folder" and vim.fs.joinpath(session.source.root, item.path) or nil
	if item.kind == "file" then
		local file = session.viewer_state.files[item.index]
		if not file then
			return
		end
		path = vim.fs.joinpath(session.source.root, file.path)
		if file.status == "renamed" and file.old_path then
			path = vim.fs.joinpath(session.source.root, file.old_path) .. " -> " .. path
		end
	end
	if not path then
		return
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
