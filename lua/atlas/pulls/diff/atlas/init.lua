local M = {}

local commits = require("atlas.pulls.diff.atlas.commits")
local explorer = require("atlas.pulls.diff.atlas.explorer")
local footer = require("atlas.pulls.diff.atlas.footer")
local git = require("atlas.pulls.diff.atlas.git")
local keymaps = require("atlas.pulls.diff.atlas.keymaps")
local renderer = require("atlas.pulls.diff.atlas.renderer")
local state = require("atlas.pulls.diff.atlas.state")
local comments = require("atlas.pulls.diff.shared.comments")
local close
local reload_session
local toggle_compact
local toggle_layout

---@param name string|nil
---@param buftype "nofile"|"nowrite"|nil
---@return integer
local function create_buffer(name, buftype)
	local buf = vim.api.nvim_create_buf(false, true)
	if name then
		vim.api.nvim_buf_set_name(buf, name)
	end
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = buftype or "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].readonly = buftype == "nowrite"
	return buf
end

---@param anchor integer
---@param buf integer
---@param direction "left"|"right"|"above"|"below"
---@param size integer|nil
---@return integer
local function split_window(anchor, buf, direction, size)
	---@type vim.api.keyset.win_config
	local config = { split = direction, win = anchor }
	if direction == "left" or direction == "right" then
		config.width = size
	else
		config.height = size
	end
	return vim.api.nvim_open_win(buf, false, config)
end

---@param name string
---@param current integer
---@return integer|nil
local function find_named_buffer(name, current)
	if name == "" then
		return nil
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if buf ~= current and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
			if not vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].buflisted and name:match("^atlas%-diff://") then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			else
				return buf
			end
		end
	end
	return nil
end

---@param buf integer
---@param name string
local function rename_buffer(buf, name)
	if vim.api.nvim_buf_get_name(buf) == name then
		return
	end
	vim.api.nvim_buf_set_name(buf, name)
end

---@param buf integer
---@param path string
local function set_filetype(buf, path)
	local filetype = path ~= "" and (vim.filetype.match({ filename = path }) or "") or ""
	if vim.bo[buf].filetype == filetype then
		return
	end
	pcall(vim.treesitter.stop, buf)
	if filetype ~= "" then
		local language = vim.treesitter.language.get_lang(filetype) or filetype
		pcall(vim.treesitter.start, buf, language)
	end
	vim.bo[buf].filetype = filetype
end

---@param buf integer
---@param lines string[]
---@param path string
local function set_buffer(buf, lines, path)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	set_filetype(buf, path)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.bo[buf].readonly = vim.bo[buf].buftype == "nowrite"
end

---@param session AtlasNativeDiffSession
---@param buf integer
---@param revision string
---@param path string
local function name_content_buffer(session, buf, revision, path)
	local root = vim.fn.fnamemodify(session.range.root, ":p"):gsub("[\\/]$", ""):gsub("\\", "/")
	root = root:gsub("^/", "")
	local relative_path = path:gsub("^[/\\]+", "")
	-- Keep the real repo, revision and path visible to file-aware plugins.
	local prefix = string.format("atlas-diff:///%s///%s/", root, revision)
	local name = prefix .. relative_path
	local duplicate = 0
	while find_named_buffer(name, buf) do
		duplicate = duplicate + 1
		local owner = string.format(".atlas-session-%d", session.tabpage)
		if duplicate > 1 then
			owner = string.format("%s-%d", owner, duplicate)
		end
		name = string.format("%s%s/%s", prefix, owner, relative_path)
	end
	rename_buffer(buf, name)
	vim.bo[buf].buflisted = true
end

---@param session AtlasNativeDiffSession
---@param document AtlasNativeDiffDocument
local function set_document_buffers(session, document)
	name_content_buffer(session, session.left.buf, session.range.base_revision, document.old.path)
	name_content_buffer(session, session.right.buf, session.range.head_revision, document.new.path)
	set_buffer(session.left.buf, document.old.lines, document.old.path)
	set_buffer(session.right.buf, document.new.lines, document.new.path)
end

---@param session AtlasNativeDiffSession
---@return boolean
local function compact_active(session)
	local document = session.document
	return session.compact and not document.binary and #document.file.hunks > 0
end

---@param session AtlasNativeDiffSession
local function render_file(session)
	renderer.file(session.document, {
		layout = session.layout,
		compact = session.compact,
		left = session.left,
		right = session.right,
	})
end

---@param session AtlasNativeDiffSession
local function render_explorer(session)
	explorer.render(session, comments.annotated_paths(session.review))
end

---@param session AtlasNativeDiffSession
local function refresh_ui(session)
	comments.render(session)
	render_explorer(session)
	commits.render(session)
	footer.render(session)
end

---@param session AtlasNativeDiffSession
---@param win integer
local function configure_content_window(session, win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local options = vim.wo[win][0]
	options.colorcolumn = ""
	options.cursorbind = false
	options.cursorcolumn = false
	options.cursorline = false
	options.foldenable = compact_active(session)
	options.foldcolumn = "0"
	options.foldmethod = "manual"
	options.list = false
	options.number = session.number
	options.relativenumber = session.relativenumber
	options.signcolumn = "yes:1"
	options.spell = false
	options.diff = false
	options.scrollbind = false
	options.wrap = false
	options.winhighlight = ""
end

---@param session AtlasNativeDiffSession
local function focus_first_hunk(session)
	local document = session.document
	if not session.right.win or not vim.api.nvim_win_is_valid(session.right.win) then
		return
	end
	local first = document.file.hunks[1]
	local right_line = first and math.max(1, math.min(#document.new.lines, first.new_start)) or 1
	vim.api.nvim_win_set_cursor(session.right.win, { right_line, 0 })
	if session.left.win and vim.api.nvim_win_is_valid(session.left.win) then
		local left_line = first and math.max(1, math.min(#document.old.lines, first.old_start)) or 1
		vim.api.nvim_win_set_cursor(session.left.win, { left_line, 0 })
	end
end

---@param session AtlasNativeDiffSession
local function cancel_job(session)
	local job = session.job
	session.job = nil
	if job then
		pcall(job.cancel)
	end
end

---@param session AtlasNativeDiffSession
---@return boolean
local function dispose_session(session)
	if session.closing then
		return false
	end
	session.closing = true
	cancel_job(session)
	footer.dispose(session)
	comments.detach(session)
	state.remove(session.tabpage)
	return true
end

---@param session AtlasNativeDiffSession
local function delete_session_buffers(session)
	for _, buf in ipairs({
		session.panel.buf,
		session.commits_panel.buf,
		session.left.buf,
		session.right.buf,
		session.footer.buf,
	}) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

---@param session AtlasNativeDiffSession
local function open_commits_panel(session)
	local panel_win = session.panel.win
	if
		not session.commits_visible
		or #session.commits == 0
		or not panel_win
		or not vim.api.nvim_win_is_valid(panel_win)
		or (session.commits_panel.win and vim.api.nvim_win_is_valid(session.commits_panel.win))
	then
		return
	end
	local height = math.max(1, math.floor(vim.api.nvim_win_get_height(panel_win) * 0.3))
	local commits_win = vim.api.nvim_win_call(panel_win, function()
		vim.cmd("belowright " .. height .. "split")
		return vim.api.nvim_get_current_win()
	end)
	session.commits_panel.win = commits_win
	vim.api.nvim_win_set_buf(commits_win, session.commits_panel.buf)
	explorer.configure_window(session, commits_win)
	vim.wo[commits_win].winfixheight = true
	commits.render(session)
end

---@param session AtlasNativeDiffSession
local function close_commits_panel(session)
	local win = session.commits_panel.win
	session.commits_panel.win = nil
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

---@param session AtlasNativeDiffSession
---@param index integer
local function select_file(session, index)
	if session.closing or not session.files[index] then
		return
	end
	cancel_job(session)
	explorer.reveal_file(session, index)
	session.pending_index = index
	render_explorer(session)

	local file = session.files[index]
	session.job = git.document(session.range, file, function(document, err)
		if session.closing then
			return
		end
		session.job = nil
		if not document then
			footer.notify(session, "error", tostring(err or "Unable to load file diff"))
			session.pending_index = nil
			render_explorer(session)
			return
		end
		session.selected_index = index
		session.pending_index = nil
		session.document = document
		set_document_buffers(session, document)
		configure_content_window(session, session.right.win)
		if session.left.win then
			configure_content_window(session, session.left.win)
		end
		render_file(session)
		focus_first_hunk(session)
		session.refresh_ui()
	end)
end

---@param session AtlasNativeDiffSession
---@param index integer
---@return integer|nil
local function next_unreviewed_file(session, index)
	for offset = 1, #session.files - 1 do
		local candidate = ((index - 1 + offset) % #session.files) + 1
		if not session.reviewed_files[session.files[candidate].path] then
			return candidate
		end
	end
	return nil
end

---@param session AtlasNativeDiffSession
local function toggle_file_reviewed(session)
	local index = explorer.file_at_cursor(session)
	if vim.api.nvim_get_current_buf() == session.panel.buf and not index then
		return
	end
	index = index or session.selected_index
	local file = session.files[index]
	if not file then
		return
	end
	local reviewed = not session.reviewed_files[file.path]
	session.reviewed_files[file.path] = reviewed
	if reviewed then
		local next_index = next_unreviewed_file(session, index)
		if next_index then
			select_file(session, next_index)
			local next_line = explorer.line_for_file(session, next_index)
			if next_line and session.panel.win and vim.api.nvim_win_is_valid(session.panel.win) then
				vim.api.nvim_win_set_cursor(session.panel.win, { next_line, 0 })
			end
			return
		end
	end
	render_explorer(session)
	local line = explorer.line_for_file(session, index)
	if line and session.panel.win and vim.api.nvim_win_is_valid(session.panel.win) then
		vim.api.nvim_win_set_cursor(session.panel.win, { line, 0 })
	end
end

---@param session AtlasNativeDiffSession
---@param direction 1|-1
local function navigate_file(session, direction)
	local order = explorer.ordered_indices(session)
	if #order == 0 then
		return
	end
	local current = session.pending_index or session.selected_index
	local position = 1
	for index, file_index in ipairs(order) do
		if file_index == current then
			position = index
			break
		end
	end
	position = ((position - 1 + direction) % #order) + 1
	select_file(session, order[position])
end

---@param session AtlasNativeDiffSession
---@param direction 1|-1
local function navigate_hunk(session, direction)
	local document = session.document
	if #document.file.hunks == 0 then
		footer.notify(session, "info", "No diff hunks in this file")
		return
	end
	local current_buf = vim.api.nvim_get_current_buf()
	local use_left = current_buf == session.left.buf
	local target_win = use_left and session.left.win or session.right.win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		return
	end
	local target_buf = use_left and session.left.buf or session.right.buf
	local line_count = vim.api.nvim_buf_line_count(target_buf)
	local seen, lines = {}, {}
	for _, hunk in ipairs(document.file.hunks) do
		local start = use_left and hunk.old_start or hunk.new_start
		local line = math.max(1, math.min(line_count, start))
		if not seen[line] then
			seen[line] = true
			table.insert(lines, line)
		end
	end
	table.sort(lines)
	vim.api.nvim_set_current_win(target_win)
	local current = vim.api.nvim_win_get_cursor(target_win)[1]
	local target
	if direction > 0 then
		for _, line in ipairs(lines) do
			if line > current then
				target = line
				break
			end
		end
		target = target or lines[1]
	else
		for index = #lines, 1, -1 do
			if lines[index] < current then
				target = lines[index]
				break
			end
		end
		target = target or lines[#lines]
	end
	vim.api.nvim_win_set_cursor(target_win, { target, 0 })
	pcall(vim.cmd.normal, { "zvzz", bang = true })
end

---@param session AtlasNativeDiffSession
local function toggle_panel(session)
	local panel_win = session.panel.win
	if panel_win and vim.api.nvim_win_is_valid(panel_win) then
		close_commits_panel(session)
		session.panel.win = nil
		vim.api.nvim_win_close(panel_win, true)
		footer.reflow(session)
		return
	end
	local anchor_win = session.layout == "side-by-side" and session.left.win or session.right.win
	if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
		return
	end
	session.panel.win = split_window(anchor_win, session.panel.buf, "left", explorer.width(session))
	explorer.configure_window(session, session.panel.win)
	render_explorer(session)
	open_commits_panel(session)
	footer.reflow(session)
end

---@param session AtlasNativeDiffSession
local function toggle_commits(session)
	if #session.commits == 0 then
		footer.notify(session, "info", "No commits available")
		return
	end
	if not session.panel.win or not vim.api.nvim_win_is_valid(session.panel.win) then
		session.commits_visible = true
		toggle_panel(session)
		return
	end
	session.commits_visible = not session.commits_visible
	if not session.commits_visible then
		close_commits_panel(session)
	else
		open_commits_panel(session)
	end
	footer.reflow(session)
end

---@param session AtlasNativeDiffSession
local function register_keymaps(session)
	keymaps.register(session, {
		active = function()
			return not session.closing
		end,
		close = function()
			close(session)
		end,
		toggle_layout = function()
			toggle_layout(session)
		end,
		toggle_compact = function()
			toggle_compact(session)
		end,
		reload = function()
			reload_session(session)
		end,
		navigate_hunk = function(direction)
			navigate_hunk(session, direction)
		end,
		navigate_file = function(direction)
			navigate_file(session, direction)
		end,
		toggle_file_reviewed = function()
			toggle_file_reviewed(session)
		end,
		toggle_panel = function()
			toggle_panel(session)
		end,
		toggle_commits = function()
			toggle_commits(session)
		end,
		select_file = function(index)
			select_file(session, index)
		end,
		refresh = function()
			comments.reload(session)
		end,
		open_item = function(buf)
			if not comments.open_at_cursor(session, buf) then
				footer.notify(session, "info", "No comment at cursor")
			end
		end,
		show_commit = function()
			commits.show_details(session)
		end,
	})
end

---@param open_options AtlasNativeDiffOpenOptions
---@param options AtlasNativeDiffSessionOptions
---@return AtlasNativeDiffSession|nil, string|nil
local function create_session(open_options, options)
	local session
	local tabpage
	local created_buffers = {}
	local ok, err = pcall(function()
		local target = open_options.target
		local right_win, launcher_buf
		local number, relativenumber
		if target then
			tabpage, right_win, launcher_buf = target.tabpage, target.win, target.buf
			number, relativenumber = target.number, target.relativenumber
			vim.api.nvim_set_current_tabpage(tabpage)
			vim.api.nvim_set_current_win(right_win)
		else
			vim.cmd("tabnew")
			tabpage = vim.api.nvim_get_current_tabpage()
			right_win = vim.api.nvim_get_current_win()
			launcher_buf = vim.api.nvim_get_current_buf()
			number = vim.wo[right_win].number
			relativenumber = vim.wo[right_win].relativenumber
		end
		table.insert(created_buffers, launcher_buf)

		local right_buf = create_buffer(nil, "nowrite")
		local left_buf = create_buffer(nil, "nowrite")
		local panel_buf = create_buffer(string.format("atlas-diff://%d/files", tabpage))
		local commits_buf = create_buffer(string.format("atlas-diff://%d/commits", tabpage))
		local footer_buf = create_buffer(string.format("atlas-diff://%d/footer", tabpage))
		vim.bo[panel_buf].filetype = "atlas-diff-files"
		vim.bo[commits_buf].filetype = "atlas-diff-commits"
		vim.bo[footer_buf].filetype = "atlas-footer"
		vim.list_extend(created_buffers, { right_buf, left_buf, panel_buf, commits_buf, footer_buf })

		vim.api.nvim_win_set_buf(right_win, right_buf)
		if vim.api.nvim_buf_is_valid(launcher_buf) then
			vim.api.nvim_buf_delete(launcher_buf, { force = true })
		end
		local panel_win
		if not options.explorer.hidden then
			local panel_width = math.min(options.explorer.width, math.max(20, vim.o.columns - 40))
			panel_win = split_window(right_win, panel_buf, "left", panel_width)
		end
		local footer_win = split_window(right_win, footer_buf, "below", 1)
		if target then
			for name, value in pairs({
				statuscolumn = target.statuscolumn,
				statusline = target.statusline,
				winbar = target.winbar,
			}) do
				vim.api.nvim_set_option_value(name, value, { win = right_win, scope = "local" })
			end
		end

		---@type AtlasNativeDiffSession
		session = {
			tabpage = tabpage,
			range = open_options.diff.range,
			files = open_options.diff.files,
			selected_index = 1,
			pending_index = nil,
			layout = options.layout,
			compact = options.compact,
			number = number,
			relativenumber = relativenumber,
			explorer = options.explorer,
			reviewed_files = {},
			collapsed_folders = {},
			panel_items = {},
			panel = { buf = panel_buf, win = panel_win },
			commits = vim.deepcopy(open_options.commits or {}),
			commit_items = {},
			commits_panel = { buf = commits_buf, win = nil },
			commits_visible = options.explorer.show_commits and #(open_options.commits or {}) > 0,
			left = { buf = left_buf, win = nil },
			right = { buf = right_buf, win = right_win },
			footer = footer.new(footer_buf, footer_win),
			job = nil,
			document = open_options.diff.document,
			review = nil,
			review_context = open_options.review,
			review_view = {
				notify = function(level, message, duration)
					footer.notify(session, level, message, duration)
				end,
				register_keymaps = function(actions)
					keymaps.register_review(session, actions)
				end,
				unregister_keymaps = function()
					keymaps.unregister_review(session)
				end,
				task_at_cursor = function()
					return explorer.task_at_cursor(session)
				end,
			},
			reload = open_options.reload,
			refresh_ui = function() end,
			closing = false,
		}
		session.refresh_ui = function()
			if not session.closing then
				refresh_ui(session)
			end
		end
		state.add(session)

		explorer.configure(session)
		footer.configure(session)
		register_keymaps(session)
		local focus_win = options.explorer.initial_focus == "explorer" and panel_win or nil
		vim.api.nvim_set_current_win(focus_win or right_win)
	end)

	if ok then
		return session, nil
	end
	if session then
		close(session)
	else
		if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
			pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tabpage) .. "tabclose")
		end
		for _, buf in ipairs(created_buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
	end
	return nil, tostring(err)
end

---@param explorer_options AtlasDiffExplorerOptions
---@return AtlasNativeDiffSessionOptions
local function session_options(explorer_options)
	local config = (require("atlas.config").options.pulls or {}).diff or {}
	return {
		layout = config.layout == "inline" and "inline" or "side-by-side",
		compact = config.compact ~= false,
		explorer = explorer_options,
	}
end

---@param session AtlasNativeDiffSession
---@return string|nil
local function initialize_session(session)
	local right_win = session.right.win
	if not right_win or not vim.api.nvim_win_is_valid(right_win) then
		return "The diff layout changed unexpectedly"
	end

	local ok, err = pcall(function()
		if session.layout == "side-by-side" then
			session.left.win = split_window(right_win, session.left.buf, "left", nil)
		end
		set_document_buffers(session, session.document)
		if session.left.win then
			configure_content_window(session, session.left.win)
		end
		configure_content_window(session, right_win)
		render_file(session)
		render_explorer(session)
		local review = session.review_context
		if review then
			comments.attach(session, review)
		end

		focus_first_hunk(session)
		footer.reflow(session)
		open_commits_panel(session)
	end)
	if not ok then
		return tostring(err)
	end
	return nil
end

---@param options AtlasNativeDiffOpenOptions
---@return string|nil
function M.open(options)
	if not options or not options.diff or not options.explorer then
		return "A prepared diff is required"
	end
	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()
	local session, create_err = create_session(options, session_options(options.explorer))
	if not session then
		return "Unable to create diff view: " .. tostring(create_err)
	end
	local initialize_err = initialize_session(session)
	if initialize_err then
		close(session)
		return "Unable to initialize diff view: " .. initialize_err
	end
	return nil
end

---@param session AtlasNativeDiffSession
---@return AtlasLoadingTarget|nil
local function replace_with_loading(session)
	local tabpage = session.tabpage
	local win = session.right.win
	if
		session.closing
		or state.get(tabpage) ~= session
		or not vim.api.nvim_tabpage_is_valid(tabpage)
		or not win
		or not vim.api.nvim_win_is_valid(win)
	then
		return nil
	end

	local statuscolumn = vim.wo[win].statuscolumn
	local statusline = vim.wo[win].statusline
	local winbar = vim.wo[win].winbar
	local buf = vim.api.nvim_create_buf(false, true)
	dispose_session(session)
	vim.api.nvim_set_current_tabpage(tabpage)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_buf(win, buf)
	for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if other ~= win then
			pcall(vim.api.nvim_win_close, other, true)
		end
	end
	delete_session_buffers(session)
	return {
		tabpage = tabpage,
		buf = buf,
		win = win,
		number = session.number,
		relativenumber = session.relativenumber,
		statuscolumn = statuscolumn,
		statusline = statusline,
		winbar = winbar,
	}
end

---@param session AtlasNativeDiffSession
---@return nil
reload_session = function(session)
	local reload = session.reload
	local target = replace_with_loading(session)
	if not target then
		return
	end
	reload(target)
end

---@param session AtlasNativeDiffSession
---@return nil
toggle_layout = function(session)
	if session.closing or not vim.api.nvim_tabpage_is_valid(session.tabpage) then
		return
	end
	if not session.right.win or not vim.api.nvim_win_is_valid(session.right.win) then
		vim.notify("[Atlas Diff] The diff layout changed unexpectedly; closing the view", vim.log.levels.WARN)
		close(session)
		return
	end
	local current_win = vim.api.nvim_get_current_win()
	local function restore_focus()
		if vim.api.nvim_win_is_valid(current_win) then
			vim.api.nvim_set_current_win(current_win)
		elseif session.right.win and vim.api.nvim_win_is_valid(session.right.win) then
			vim.api.nvim_set_current_win(session.right.win)
		end
	end
	local function render_layout()
		configure_content_window(session, session.right.win)
		if session.left.win then
			configure_content_window(session, session.left.win)
		end
		render_file(session)
		session.refresh_ui()
		footer.reflow(session)
	end

	if session.layout == "side-by-side" then
		local left_win = session.left.win
		local ok, err = pcall(function()
			if left_win and vim.api.nvim_win_is_valid(left_win) then
				if vim.api.nvim_get_current_win() == left_win then
					vim.api.nvim_set_current_win(session.right.win)
				end
				vim.api.nvim_win_close(left_win, true)
			end
			session.left.win = nil
			session.layout = "inline"
			render_layout()
		end)
		restore_focus()
		if not ok then
			footer.notify(session, "error", "Unable to switch diff layout: " .. tostring(err))
		end
		return
	end

	local left_win
	local ok, err = pcall(function()
		left_win = split_window(session.right.win, session.left.buf, "left", nil)
		session.left.win = left_win
		session.layout = "side-by-side"
		render_layout()
	end)
	if not ok then
		session.layout = "inline"
		if left_win and vim.api.nvim_win_is_valid(left_win) then
			if vim.api.nvim_get_current_win() == left_win then
				vim.api.nvim_set_current_win(session.right.win)
			end
			pcall(vim.api.nvim_win_close, left_win, true)
		end
		session.left.win = nil
		pcall(render_layout)
		footer.notify(session, "error", "Unable to switch diff layout: " .. tostring(err))
	end
	restore_focus()
end

---@param session AtlasNativeDiffSession
---@return nil
toggle_compact = function(session)
	if session.closing or not vim.api.nvim_tabpage_is_valid(session.tabpage) then
		return
	end
	if not session.right.win or not vim.api.nvim_win_is_valid(session.right.win) then
		vim.notify("[Atlas Diff] The diff layout changed unexpectedly; closing the view", vim.log.levels.WARN)
		close(session)
		return
	end
	local document = session.document
	if not session.compact and (document.binary or #document.file.hunks == 0) then
		footer.notify(session, "info", "This file has no textual diff hunks")
		return
	end
	session.compact = not session.compact
	configure_content_window(session, session.right.win)
	if session.left.win then
		configure_content_window(session, session.left.win)
	end
	render_file(session)
end

---@param session AtlasNativeDiffSession
---@return nil
close = function(session)
	if not dispose_session(session) then
		return
	end
	if vim.api.nvim_tabpage_is_valid(session.tabpage) then
		local tabnr = vim.api.nvim_tabpage_get_number(session.tabpage)
		pcall(vim.cmd, tabnr .. "tabclose")
	end
	delete_session_buffers(session)
end

local autocmd_group = vim.api.nvim_create_augroup("AtlasNativeDiff", { clear = true })

vim.api.nvim_create_autocmd("TabClosed", {
	group = autocmd_group,
	callback = function()
		local closed = {}
		for _, session in pairs(state.all()) do
			if not vim.api.nvim_tabpage_is_valid(session.tabpage) then
				table.insert(closed, session)
			end
		end
		for _, session in ipairs(closed) do
			close(session)
		end
	end,
})

vim.api.nvim_create_autocmd("WinClosed", {
	group = autocmd_group,
	callback = function(args)
		local closed_win = tonumber(args.match)
		vim.schedule(function()
			for _, session in pairs(state.all()) do
				if not session.closing then
					if closed_win == session.commits_panel.win then
						session.commits_panel.win = nil
						session.commits_visible = false
						footer.reflow(session)
					elseif closed_win == session.panel.win then
						session.panel.win = nil
						close_commits_panel(session)
						footer.reflow(session)
					elseif closed_win == session.footer.win then
						session.footer.win = nil
					elseif closed_win == session.left.win or closed_win == session.right.win then
						close(session)
					end
				end
			end
		end)
	end,
})

local function resize_current_view()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local session = state.get(tabpage)
	if not session or session.closing then
		return
	end
	explorer.configure(session)
	if session.right.win then
		configure_content_window(session, session.right.win)
	end
	if session.left.win then
		configure_content_window(session, session.left.win)
	end
	footer.configure(session)
	render_file(session)
	session.refresh_ui()
	footer.reflow(session)
end

vim.api.nvim_create_autocmd({ "WinResized", "TabEnter" }, {
	group = autocmd_group,
	callback = function()
		vim.schedule(resize_current_view)
	end,
})

return M
