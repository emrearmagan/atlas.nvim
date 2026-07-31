local M = {}

local comments = require("atlas.pulls.diff.shared.comments")
local overlay = require("atlas.pulls.diff.shared.comments.overlay")
local resolver = require("atlas.core.keymaps")

---@type table<integer, AtlasCodeDiffReview>
local sessions = {}
local READY_RETRIES = 80

---@class AtlasCodeDiffRange
---@field start_line integer
---@field end_line integer

---@class AtlasCodeDiffChange
---@field original AtlasCodeDiffRange
---@field modified AtlasCodeDiffRange

---@class AtlasCodeDiffSession
---@field git_root string|nil
---@field original_path string|nil
---@field modified_path string|nil
---@field original { relative: string|nil }|nil
---@field modified { relative: string|nil }|nil
---@field original_revision string|nil
---@field modified_revision string|nil
---@field original_bufnr integer|nil
---@field modified_bufnr integer|nil
---@field original_win integer|nil
---@field modified_win integer|nil
---@field layout "side-by-side"|"inline"
---@field compact_mode boolean|nil
---@field stored_diff_result { changes: AtlasCodeDiffChange[] }|nil
---@field explorer AtlasCodeDiffExplorer|nil

---@class AtlasCodeDiffSelection
---@field path string
---@field status string|nil

---@class AtlasCodeDiffExplorer
---@field bufnr integer|nil
---@field git_root string|nil
---@field base_revision string|nil
---@field target_revision string|nil
---@field current_selection AtlasCodeDiffSelection|nil
---@field current_file_path string|nil

---@class AtlasCodeDiffLifecycle
---@field get_session fun(tabpage: integer): AtlasCodeDiffSession|nil
---@field get_explorer fun(tabpage: integer): AtlasCodeDiffExplorer|nil
---@field find_tabpage_by_buffer fun(buf: integer): integer|nil
---@field close fun(tabpage: integer): boolean

---@class AtlasCodeDiffKeymaps
---@field view? table<string, string|string[]|false>

---@class AtlasCodeDiffReview
---@field tabpage integer
---@field lifecycle AtlasCodeDiffLifecycle
---@field context AtlasPreparedReviewContext
---@field reload fun()|nil
---@field facade AtlasReviewSession|nil
---@field actions AtlasReviewKeymapActions|nil
---@field mapped table<integer, table<string, table|false>>
---@field help_buffers table<string, integer>
---@field group integer
---@field expected_path string|nil
---@field status string|nil
---@field generation integer
---@field attached boolean
---@field closed boolean

---@class AtlasCodeDiffAttachOptions
---@field reload fun()|nil

---@class AtlasCodeDiffHelpGroup
---@field name string
---@field items AtlasHelpKeyItem[]
---@field index integer

---@param value string|nil
---@return string
local function clean_path(value)
	return tostring(value or ""):gsub("\\", "/"):gsub("/+$", "")
end

---@param root string
---@param path string|nil
---@return string
local function relative_path(root, path)
	path = clean_path(path)
	root = clean_path(root)
	local prefix = root ~= "" and root .. "/" or ""
	if prefix ~= "" and path:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return path:gsub("^%./", "")
end

---@param ... string|nil
---@return string
local function revision(...)
	for index = 1, select("#", ...) do
		local value = tostring(select(index, ...) or "")
		if value ~= "" then
			return value
		end
	end
	return ""
end

---@param code string|nil
---@param old_path string
---@param new_path string
---@return DiffFileStatus
local function file_status(code, old_path, new_path)
	local statuses = {
		A = "added",
		D = "deleted",
		M = "modified",
		R = "renamed",
		T = "type_changed",
	}
	local status = statuses[tostring(code or ""):sub(1, 1)]
	if status then
		return status
	end
	if old_path == "" then
		return "added"
	end
	if new_path == "" then
		return "deleted"
	end
	return old_path ~= new_path and "renamed" or "modified"
end

---@param buf integer
---@param path string
---@return string[]
local function buffer_lines(buf, path)
	if path == "" or not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param old_start integer
---@param old_count integer
---@param new_start integer
---@param new_count integer
---@param old_lines string[]
---@param new_lines string[]
---@return DiffHunk
local function make_hunk(old_start, old_count, new_start, new_count, old_lines, new_lines)
	local lines = {}
	for offset = 0, old_count - 1 do
		local content = old_lines[old_start + offset] or ""
		table.insert(lines, {
			kind = "remove",
			text = "-" .. content,
			content = content,
			old_line = old_start + offset,
			new_line = nil,
		})
	end
	for offset = 0, new_count - 1 do
		local content = new_lines[new_start + offset] or ""
		table.insert(lines, {
			kind = "add",
			text = "+" .. content,
			content = content,
			old_line = nil,
			new_line = new_start + offset,
		})
	end
	return {
		header = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start, new_count),
		context = "",
		old_start = old_start,
		old_count = old_count,
		new_start = new_start,
		new_count = new_count,
		additions = new_count,
		deletions = old_count,
		lines = lines,
	}
end

---@param changes AtlasCodeDiffChange[]
---@param status DiffFileStatus
---@param old_lines string[]
---@param new_lines string[]
---@return DiffHunk[]
local function hunks(changes, status, old_lines, new_lines)
	local result = {}
	for _, change in ipairs(changes) do
		local old_start = math.max(1, change.original.start_line)
		local new_start = math.max(1, change.modified.start_line)
		table.insert(
			result,
			make_hunk(
				old_start,
				math.max(0, change.original.end_line - change.original.start_line),
				new_start,
				math.max(0, change.modified.end_line - change.modified.start_line),
				old_lines,
				new_lines
			)
		)
	end
	if #result == 0 and status == "added" and #new_lines > 0 then
		table.insert(result, make_hunk(1, 0, 1, #new_lines, old_lines, new_lines))
	elseif #result == 0 and status == "deleted" and #old_lines > 0 then
		table.insert(result, make_hunk(1, #old_lines, 1, 0, old_lines, new_lines))
	end
	return result
end

---@param entry AtlasCodeDiffReview
local function unmap(entry)
	for _, buf in pairs(entry.help_buffers) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
	entry.help_buffers = {}
	for buf, mappings in pairs(entry.mapped) do
		if vim.api.nvim_buf_is_valid(buf) then
			for key, previous in pairs(mappings) do
				pcall(vim.keymap.del, "n", key, { buffer = buf })
				if previous then
					pcall(vim.api.nvim_buf_call, buf, function()
						vim.fn.mapset("n", false, previous)
					end)
				end
			end
		end
	end
	entry.mapped = {}
end

---@param entry AtlasCodeDiffReview
---@param buf integer
---@param key string
---@return boolean
local function remember_mapping(entry, buf, key)
	entry.mapped[buf] = entry.mapped[buf] or {}
	if entry.mapped[buf][key] ~= nil then
		return false
	end
	local previous = vim.api.nvim_buf_call(buf, function()
		return vim.fn.maparg(key, "n", false, true)
	end)
	entry.mapped[buf][key] = not vim.tbl_isempty(previous) and previous.buffer == 1 and previous or false
	return true
end

---@param entry AtlasCodeDiffReview
---@param buf integer
---@param action AtlasKeymapActionId
---@param description string
---@param callback fun()
---@param reserved table<string, boolean>
---@param active fun(): boolean|nil
local function map(entry, buf, action, description, callback, reserved, active)
	for _, key in ipairs(resolver.resolve(action) or {}) do
		if not reserved[vim.keycode(key)] and remember_mapping(entry, buf, key) then
			vim.keymap.set("n", key, function()
				if not entry.closed and entry.actions and (active or entry.actions.active)() then
					callback()
				end
			end, { buffer = buf, silent = true, nowait = true, desc = description })
		end
	end
end

---@return AtlasCodeDiffKeymaps
local function configured_keymaps()
	local ok, config = pcall(require, "codediff.config")
	return ok and config.options and config.options.keymaps or {}
end
---@param view table
---@return table<string, boolean>
local function reserved_keys(view)
	local result = {}
	for _, value in pairs(view) do
		local keys = type(value) == "table" and value or { value }
		for _, key in ipairs(keys) do
			if type(key) == "string" and key ~= "" then
				result[vim.keycode(key)] = true
			end
		end
	end
	return result
end

---@param action AtlasKeymapActionId
---@param reserved table<string, boolean>
---@return string[]
local function review_keys(action, reserved)
	local result = {}
	for _, key in ipairs(resolver.resolve(action) or {}) do
		if not reserved[vim.keycode(key)] then
			table.insert(result, key)
		end
	end
	return result
end

---@param view table<string, string|string[]|false>
---@return string[]
local function help_keys(view)
	local reserved = reserved_keys(view)
	local result = review_keys("ui.help", reserved)
	if #result == 0 and not reserved[vim.keycode("?")] then
		table.insert(result, "?")
	end
	return result
end

---@param items AtlasHelpKeyItem[]
---@param key string|string[]|false|nil
---@param desc string
---@param index integer
local function add_help_item(items, key, desc, index)
	if not key or key == "" or (type(key) == "table" and #key == 0) then
		return
	end
	table.insert(items, { key = key, desc = desc, index = index })
end

---@param view table<string, string|string[]|false>
---@param reloadable boolean
---@param include_comments boolean
---@return AtlasCodeDiffHelpGroup[]
local function help_groups(view, reloadable, include_comments)
	local reserved = reserved_keys(view)
	local general = {}
	add_help_item(general, help_keys(view), "Toggle Atlas help", 10)
	add_help_item(general, review_keys("ui.refresh", reserved), "Refresh review comments", 20)
	if reloadable then
		add_help_item(general, review_keys("ui.refresh_view", reserved), "Reload pull request diff", 21)
	end
	add_help_item(general, review_keys("ui.open_in_browser", reserved), "Open pull request in browser", 30)

	local groups = { { name = "General", items = general, index = 90 } }
	if not include_comments then
		return groups
	end

	local navigation = {}
	add_help_item(navigation, review_keys("pulls.review.previous_comment", reserved), "Previous comment", 10)
	add_help_item(navigation, review_keys("pulls.review.next_comment", reserved), "Next comment", 11)

	local review = {}
	add_help_item(review, review_keys("pulls.review.view_thread", reserved), "Open comment thread", 10)
	add_help_item(review, review_keys("pulls.review.toggle_resolved", reserved), "Toggle resolved", 11)
	add_help_item(review, review_keys("pulls.review.add_pending_comment", reserved), "Add pending comment", 20)
	add_help_item(review, review_keys("pulls.review.add_comment", reserved), "Add comment", 21)
	add_help_item(review, review_keys("ui.toggle_fold", reserved), "Toggle review thread", 30)
	add_help_item(review, review_keys("ui.toggle_all_folds", reserved), "Toggle all review threads", 31)
	table.insert(groups, { name = "Review", items = review, index = 110 })
	table.insert(groups, { name = "Navigation", items = navigation, index = 120 })
	return groups
end

---@param entry AtlasCodeDiffReview
local function reload(entry)
	if not entry.reload then
		return
	end
	local callback = entry.reload
	local reuse_tab = #vim.api.nvim_list_tabpages() == 1
	if not entry.lifecycle.close(entry.tabpage) then
		return
	end
	---@type AtlasLoadingTarget|nil
	local target
	if reuse_tab then
		local win = vim.api.nvim_get_current_win()
		target = {
			tabpage = vim.api.nvim_get_current_tabpage(),
			buf = vim.api.nvim_get_current_buf(),
			win = win,
			number = vim.wo[win].number,
			relativenumber = vim.wo[win].relativenumber,
			statuscolumn = vim.wo[win].statuscolumn,
			statusline = vim.wo[win].statusline,
			winbar = vim.wo[win].winbar,
		}
	end
	vim.schedule(function()
		callback(target)
	end)
end

---@param entry AtlasCodeDiffReview
---@param buf integer
---@param active fun(): boolean
---@param view table<string, string|string[]|false>
---@param include_comments boolean
local function map_help(entry, buf, active, view, include_comments)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local help = require("atlas.ui.popups.help")
	local scope = include_comments and "review" or "explorer"
	local help_buf = entry.help_buffers[scope]
	if not help_buf or not vim.api.nvim_buf_is_valid(help_buf) then
		help_buf = vim.api.nvim_create_buf(false, true)
		entry.help_buffers[scope] = help_buf
		for _, group in ipairs(help_groups(view, entry.reload ~= nil, include_comments)) do
			help.register(group.name, group.items, { buffer = help_buf, index = group.index })
		end
	end
	for _, key in ipairs(help_keys(view)) do
		if remember_mapping(entry, buf, key) then
			vim.keymap.set("n", key, function()
				if not entry.closed and active() then
					help.toggle({ buffer = help_buf })
				end
			end, { buffer = buf, silent = true, nowait = true, desc = "Atlas help" })
		end
	end
end

---@param entry AtlasCodeDiffReview
local function map_review(entry)
	unmap(entry)
	local facade = entry.facade
	local actions = entry.actions
	if not facade or not actions then
		return
	end
	local configured = configured_keymaps()
	local view = configured.view or {}
	local reserved = reserved_keys(view)
	for _, buf in ipairs({ facade.left.buf, facade.right.buf }) do
		if vim.api.nvim_buf_is_valid(buf) and not entry.mapped[buf] then
			map_help(entry, buf, actions.active, view, true)
			map(entry, buf, "pulls.review.toggle_resolved", "Toggle resolved", function()
				actions.toggle_resolved(buf)
			end, reserved)
			map(entry, buf, "pulls.review.add_pending_comment", "Add pending inline comment", function()
				actions.add_comment(buf, true)
			end, reserved)
			map(entry, buf, "pulls.review.add_comment", "Add inline comment", function()
				actions.add_comment(buf, false)
			end, reserved)
			map(entry, buf, "pulls.review.view_thread", "Open comment thread", function()
				comments.open_at_cursor(facade, buf)
			end, reserved)
			map(entry, buf, "ui.toggle_fold", "Toggle review thread", function()
				if not actions.toggle_thread(buf) then
					pcall(vim.cmd.normal, { "za", bang = true })
				end
			end, reserved)
			map(entry, buf, "ui.toggle_all_folds", "Toggle all review threads", function()
				if not actions.toggle_all_threads() then
					pcall(vim.cmd.normal, { "zA", bang = true })
				end
			end, reserved)
			map(entry, buf, "pulls.review.previous_comment", "Previous review comment", function()
				actions.jump_comment(buf, -1)
			end, reserved)
			map(entry, buf, "pulls.review.next_comment", "Next review comment", function()
				actions.jump_comment(buf, 1)
			end, reserved)
			map(entry, buf, "ui.open_in_browser", "Open pull request in browser", actions.open_in_browser, reserved)
			map(entry, buf, "ui.refresh", "Refresh review comments", function()
				comments.reload(facade)
			end, reserved)
			if entry.reload then
				map(entry, buf, "ui.refresh_view", "Reload pull request diff", function()
					reload(entry)
				end, reserved)
			end
		end
	end

	local raw = entry.lifecycle.get_session(entry.tabpage)
	local explorer = raw and (raw.explorer or entry.lifecycle.get_explorer(entry.tabpage))
	local explorer_buf = explorer and explorer.bufnr
	if explorer_buf and vim.api.nvim_buf_is_valid(explorer_buf) and not entry.mapped[explorer_buf] then
		local function active()
			return vim.api.nvim_get_current_tabpage() == entry.tabpage
		end
		map_help(entry, explorer_buf, active, view, false)
		map(entry, explorer_buf, "ui.refresh", "Refresh review comments", function()
			comments.reload(facade)
		end, reserved, active)
		if entry.reload then
			map(entry, explorer_buf, "ui.refresh_view", "Reload pull request diff", function()
				reload(entry)
			end, reserved, active)
		end
		map(
			entry,
			explorer_buf,
			"ui.open_in_browser",
			"Open pull request in browser",
			actions.open_in_browser,
			reserved,
			active
		)
	end
end

---@param entry AtlasCodeDiffReview
---@return boolean
local function sync(entry)
	if entry.closed or not vim.api.nvim_tabpage_is_valid(entry.tabpage) then
		return false
	end
	---@type AtlasCodeDiffSession|nil
	local raw = entry.lifecycle.get_session(entry.tabpage)
	if not raw or not raw.stored_diff_result then
		return false
	end
	local explorer = raw.explorer or entry.lifecycle.get_explorer(entry.tabpage)
	local root = clean_path(raw.git_root or (explorer and explorer.git_root))
	local old_path = relative_path(root, raw.original_path or (raw.original and raw.original.relative))
	local new_path = relative_path(root, raw.modified_path or (raw.modified and raw.modified.relative))
	local path = new_path ~= "" and new_path or old_path
	local status = file_status(entry.status, old_path, new_path)
	if root == "" or path == "" then
		return false
	end
	if entry.expected_path and entry.expected_path ~= old_path and entry.expected_path ~= new_path then
		return false
	end
	if
		not raw.original_bufnr
		or not raw.modified_bufnr
		or not vim.api.nvim_buf_is_valid(raw.original_bufnr)
		or not vim.api.nvim_buf_is_valid(raw.modified_bufnr)
	then
		return false
	end
	local left_buf, left_win = raw.original_bufnr, raw.original_win
	local right_buf, right_win = raw.modified_bufnr, raw.modified_win
	local inline_deleted = status == "deleted"
		and raw.layout == "inline"
		and right_win
		and vim.api.nvim_win_is_valid(right_win)
		and vim.api.nvim_win_get_buf(right_win) == left_buf
	if inline_deleted then
		left_win = right_win
		right_win = nil
	elseif right_win and vim.api.nvim_win_is_valid(right_win) and vim.api.nvim_win_get_buf(right_win) ~= right_buf then
		return false
	elseif
		left_win
		and left_win ~= right_win
		and vim.api.nvim_win_is_valid(left_win)
		and vim.api.nvim_win_get_buf(left_win) ~= left_buf
	then
		return false
	end

	local old_lines = buffer_lines(left_buf, old_path)
	local new_lines = status == "deleted" and {} or buffer_lines(right_buf, new_path)
	local file_hunks = hunks(raw.stored_diff_result.changes or {}, status, old_lines, new_lines)
	local file = {
		path = path,
		old_path = old_path ~= "" and old_path ~= path and old_path or nil,
		status = status,
		hunks = file_hunks,
	}
	local previous = entry.facade
	local buffers_changed = not previous or previous.left.buf ~= left_buf or previous.right.buf ~= right_buf
	if previous and (previous.left.buf ~= left_buf or previous.right.buf ~= right_buf) then
		overlay.clear_comments(previous.left.buf)
		overlay.clear_comments(previous.right.buf)
	end
	local context = entry.context
	local facade = previous
		or {
			tabpage = entry.tabpage,
			files = {},
			selected_index = 1,
			layout = "side-by-side",
			compact = false,
			left = { buf = left_buf, win = left_win },
			right = { buf = right_buf, win = right_win },
			review = nil,
			closing = false,
		}
	facade.range = {
		root = root,
		base_revision = revision(
			context.pr.destination.commit_hash,
			explorer and explorer.base_revision,
			raw.original_revision
		),
		head_revision = revision(
			context.pr.source.commit_hash,
			explorer and explorer.target_revision,
			raw.modified_revision
		),
	}
	facade.files = { file }
	facade.selected_index = 1
	facade.layout = raw.layout == "inline" and not inline_deleted and "inline" or "side-by-side"
	facade.compact = raw.compact_mode == true
	facade.left = { buf = left_buf, win = left_win }
	facade.right = { buf = right_buf, win = right_win }
	facade.document = {
		file = file,
		old = { path = old_path ~= "" and old_path or path, lines = old_lines },
		new = { path = new_path ~= "" and new_path or path, lines = new_lines },
		binary = false,
	}
	entry.facade = facade
	facade.refresh_ui = function()
		comments.render(facade)
	end
	facade.review_view = {
		notify = function(level, message)
			local notify_level = level == "error" and vim.log.levels.ERROR
				or level == "warn" and vim.log.levels.WARN
				or vim.log.levels.INFO
			vim.notify("[Atlas Review] " .. message, notify_level)
		end,
		register_keymaps = function(actions)
			entry.actions = actions
			map_review(entry)
		end,
		unregister_keymaps = function()
			entry.actions = nil
			unmap(entry)
		end,
		task_at_cursor = function()
			return nil
		end,
	}
	if not entry.attached then
		local ok, err = pcall(comments.attach, facade, context)
		if not ok then
			comments.detach(facade)
			vim.notify("[Atlas Review] Unable to load comments: " .. tostring(err), vim.log.levels.ERROR)
		else
			entry.attached = true
		end
	else
		if buffers_changed then
			map_review(entry)
		end
		comments.render(facade)
	end
	return true
end

---@param entry AtlasCodeDiffReview
local function wait_until_ready(entry)
	entry.generation = entry.generation + 1
	local generation = entry.generation
	local attempt = 0
	local function check()
		if entry.closed or entry.generation ~= generation then
			return
		end
		if sync(entry) then
			return
		end
		attempt = attempt + 1
		if attempt < READY_RETRIES then
			vim.defer_fn(check, 25)
		end
	end
	vim.schedule(check)
end

---@param entry AtlasCodeDiffReview
local function register_events(entry)
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffFileSelect",
		callback = function(args)
			if args.data and args.data.tabpage == entry.tabpage then
				local raw = entry.lifecycle.get_session(entry.tabpage)
				local root = clean_path(raw and (raw.git_root or (raw.explorer and raw.explorer.git_root)))
				entry.expected_path = relative_path(root, args.data.path)
				entry.status = args.data.status
				wait_until_ready(entry)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffVirtualFileLoaded",
		callback = function(args)
			local buf = args.data and args.data.buf
			if buf and entry.lifecycle.find_tabpage_by_buffer(buf) == entry.tabpage then
				wait_until_ready(entry)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffClose",
		callback = function(args)
			if args.data and args.data.tabpage == entry.tabpage then
				M.detach(entry.tabpage)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter" }, {
		group = entry.group,
		callback = function()
			if vim.api.nvim_get_current_tabpage() == entry.tabpage then
				wait_until_ready(entry)
			end
		end,
	})
end

---@param context AtlasPreparedReviewContext
---@param tabpage integer|nil
---@param opts AtlasCodeDiffAttachOptions|nil
---@return string|nil err
function M.attach(context, tabpage, opts)
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
	if not ok then
		return "CodeDiff lifecycle is unavailable"
	end
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not lifecycle.get_session(tabpage) then
		return "CodeDiff session is unavailable"
	end
	M.detach(tabpage)
	---@type AtlasCodeDiffReview
	local entry = {
		tabpage = tabpage,
		lifecycle = lifecycle,
		context = context,
		reload = opts and opts.reload or nil,
		facade = nil,
		actions = nil,
		mapped = {},
		help_buffers = {},
		group = vim.api.nvim_create_augroup("AtlasCodeDiffReview" .. tabpage, { clear = true }),
		expected_path = nil,
		status = nil,
		generation = 0,
		attached = false,
		closed = false,
	}
	sessions[tabpage] = entry
	local raw = lifecycle.get_session(tabpage)
	local explorer = raw.explorer or lifecycle.get_explorer(tabpage)
	local selection = explorer and explorer.current_selection
	local selected_path = selection and selection.path or (explorer and explorer.current_file_path)
	if selected_path then
		entry.expected_path = relative_path(clean_path(raw.git_root or explorer.git_root), selected_path)
		entry.status = selection and selection.status or nil
	end
	register_events(entry)
	wait_until_ready(entry)
	return nil
end

---@param tabpage integer|nil
function M.detach(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	local entry = sessions[tabpage]
	if not entry then
		return
	end
	sessions[tabpage] = nil
	entry.closed = true
	entry.generation = entry.generation + 1
	if entry.facade then
		entry.facade.closing = true
		comments.detach(entry.facade)
	end
	unmap(entry)
	pcall(vim.api.nvim_del_augroup_by_id, entry.group)
end

return M
