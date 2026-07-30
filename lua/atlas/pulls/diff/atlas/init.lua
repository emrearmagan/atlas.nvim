local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local git = require("atlas.pulls.diff.atlas.git")
local keymaps = require("atlas.pulls.diff.atlas.keymaps")
local renderer = require("atlas.pulls.diff.atlas.renderer")
local state = require("atlas.pulls.diff.atlas.state")

---@param buftype "nofile"|"nowrite"
---@return integer
local function create_buffer(buftype)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = buftype
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].readonly = buftype == "nowrite"
	return buf
end

---@param anchor integer
---@param buf integer
---@return integer
local function create_explorer(anchor, buf)
	return vim.api.nvim_open_win(buf, false, {
		split = "left",
		win = anchor,
		width = math.min(36, math.max(20, vim.o.columns - 40)),
	})
end

---@param session AtlasNativeDiffSession
local function configure_content(session)
	local win = session.content.win
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local options = vim.wo[win][0]
	options.cursorline = false
	options.diff = false
	options.foldcolumn = "0"
	options.number = session.number
	options.relativenumber = session.relativenumber
	options.scrollbind = false
	options.signcolumn = "no"
	options.wrap = false
end

---@param buf integer
---@param path string
local function set_filetype(buf, path)
	local filetype = vim.filetype.match({ filename = path }) or ""
	if vim.bo[buf].filetype ~= filetype then
		vim.bo[buf].filetype = filetype
	end
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
	vim.bo[buf].readonly = true
end

---@param session AtlasNativeDiffSession
---@param path string
local function name_content_buffer(session, path)
	local root = vim.fn.fnamemodify(session.range.root, ":p"):gsub("[\\/]$", ""):gsub("\\", "/")
	root = root:gsub("^/", "")
	local relative_path = path:gsub("^[/\\]+", "")
	-- Keep the real repo, revision and path visible to file-aware plugins.
	local prefix = string.format("atlas-diff:///%s///%s/", root, session.range.head_revision)
	local name = prefix .. relative_path
	local ok = pcall(vim.api.nvim_buf_set_name, session.content.buf, name)
	if not ok then
		name = string.format("%s.atlas-session-%d/%s", prefix, session.tabpage, relative_path)
		vim.api.nvim_buf_set_name(session.content.buf, name)
	end
	vim.bo[session.content.buf].buflisted = true
end

---@param session AtlasNativeDiffSession
local function cancel_job(session)
	local job = session.job
	session.job = nil
	if job then
		pcall(job.cancel)
	end
end

local close
local select_file

---@param session AtlasNativeDiffSession
---@param document AtlasNativeDiffDocument
local function show_document(session, document)
	session.document = document
	name_content_buffer(session, document.new.path)
	set_buffer(session.content.buf, document.new.lines, document.new.path)
	configure_content(session)
	renderer.file(document, session.content.buf, session.content.win)
	explorer.render(session)
end

---@param session AtlasNativeDiffSession
---@param index integer
select_file = function(session, index)
	local file = session.files[index]
	if not file or session.closing then
		return
	end
	cancel_job(session)
	session.pending_index = index
	explorer.render(session)
	local finished = false
	local request = git.document(session.range, file, function(document, err)
		finished = true
		if session.closing then
			return
		end
		session.job = nil
		session.pending_index = nil
		if not document then
			vim.notify("[Atlas Diff] " .. tostring(err or "Unable to load file diff"), vim.log.levels.ERROR)
			explorer.render(session)
			return
		end
		session.selected_index = index
		show_document(session, document)
	end)
	if finished then
		request.cancel()
	else
		session.job = request
	end
end

---@param session AtlasNativeDiffSession
close = function(session)
	if session.closing then
		return
	end
	session.closing = true
	cancel_job(session)
	state.remove(session.tabpage)
	if vim.api.nvim_tabpage_is_valid(session.tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(session.tabpage) .. "tabclose")
	end
	for _, buf in ipairs({ session.panel.buf, session.content.buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

---@param options AtlasNativeDiffOpenOptions
---@return AtlasNativeDiffSession|nil, string|nil
local function create_session(options)
	local source_win = vim.api.nvim_get_current_win()
	local number = vim.wo[source_win].number
	local relativenumber = vim.wo[source_win].relativenumber
	local tabpage
	local buffers = {}
	local session
	local ok, err = pcall(function()
		vim.cmd("tabnew")
		tabpage = vim.api.nvim_get_current_tabpage()
		local content_win = vim.api.nvim_get_current_win()
		local launcher_buf = vim.api.nvim_get_current_buf()
		local content_buf = create_buffer("nowrite")
		local panel_buf = create_buffer("nofile")
		buffers = { launcher_buf, content_buf, panel_buf }
		vim.bo[panel_buf].filetype = "atlas-diff-files"
		vim.api.nvim_win_set_buf(content_win, content_buf)
		vim.api.nvim_buf_delete(launcher_buf, { force = true })
		local panel_win = create_explorer(content_win, panel_buf)

		---@type AtlasNativeDiffSession
		session = {
			tabpage = tabpage,
			range = options.diff.range,
			files = options.diff.files,
			selected_index = 1,
			pending_index = nil,
			panel_items = {},
			panel = { buf = panel_buf, win = panel_win },
			content = { buf = content_buf, win = content_win },
			number = number,
			relativenumber = relativenumber,
			document = options.diff.document,
			job = nil,
			closing = false,
		}
		state.add(session)
		explorer.configure(panel_win)
		configure_content(session)
		keymaps.register(session, {
			close = function()
				close(session)
			end,
			select_file = function()
				local index = explorer.file_at_cursor(session)
				if index then
					select_file(session, index)
				end
			end,
		})
		vim.api.nvim_set_current_win(panel_win)
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
		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
	end
	return nil, tostring(err)
end

---@param options AtlasNativeDiffOpenOptions
---@return string|nil err
function M.open(options)
	if not options or not options.diff then
		return "A prepared diff is required"
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()
	local session, err = create_session(options)
	if not session then
		return "Unable to create diff view: " .. tostring(err)
	end
	local ok, render_err = pcall(show_document, session, options.diff.document)
	if not ok then
		close(session)
		return "Unable to render diff view: " .. tostring(render_err)
	end
	return nil
end

local cleanup_group = vim.api.nvim_create_augroup("AtlasNativeDiffCleanup", { clear = true })

vim.api.nvim_create_autocmd("TabClosed", {
	group = cleanup_group,
	callback = function()
		for _, session in pairs(state.all()) do
			if not vim.api.nvim_tabpage_is_valid(session.tabpage) then
				close(session)
			end
		end
	end,
})

vim.api.nvim_create_autocmd("WinClosed", {
	group = cleanup_group,
	callback = function(args)
		local win = tonumber(args.match)
		for _, session in pairs(state.all()) do
			if not session.closing and (session.panel.win == win or session.content.win == win) then
				vim.schedule(function()
					if state.get(session.tabpage) == session then
						close(session)
					end
				end)
				return
			end
		end
	end,
})

vim.api.nvim_create_autocmd("WinResized", {
	group = cleanup_group,
	callback = function()
		local session = state.get(vim.api.nvim_get_current_tabpage())
		if not session or session.closing then
			return
		end
		explorer.configure(session.panel.win)
	end,
})

return M
