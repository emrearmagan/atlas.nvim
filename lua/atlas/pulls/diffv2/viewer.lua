local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local atlas = require("atlas.pulls.diffv2.atlas")
local keymaps = require("atlas.pulls.diffv2.keymaps")
local commits = require("atlas.pulls.diffv2.ui.commits")
local diff_statusline = require("atlas.pulls.diffv2.ui.statusline")
local explorer = require("atlas.pulls.diffv2.ui.explorer")
local picker = require("atlas.ui.picker")
local statusline = require("atlas.ui.statusline")

local M = {}

-- Those are the only supported renderer for now. Other commands will simply just open the diff with no built-in stuff.
local renderers = {
	AtlasDiff = "atlas.pulls.diffv2.atlas",
	CodeDiff = "atlas.pulls.diffv2.codediff",
	DiffviewOpen = "atlas.pulls.diffv2.diffview",
}

---@class AtlasDiffV2Renderer
---@field open fun(result: AtlasDiffV2Result): table
---@field setup_keymaps fun(view: table, groups: { name: string, items: AtlasHelpKeyItem[] }[])
---@field dispose fun(view: table)

---@class AtlasDiffV2Session
---@field data AtlasDiffV2Result
---@field renderer AtlasDiffV2Renderer
---@field view { tabpage: integer, left?: { buf: integer, win?: integer }, right: { buf: integer, win: integer } }
---@field explorer AtlasDiffV2Explorer
---@field commits { buf: integer, win?: integer, shown: boolean, items: PullsCommit[], cursor_row: integer, group: integer }
---@field reviewed_files table<string, boolean>
---@field statusline AtlasStatusline
---@field group integer|nil
---@field closed boolean

local function close_tab(tabpage)
	if #vim.api.nvim_list_tabpages() == 1 then
		vim.cmd.tabnew()
		vim.wo.statusline = vim.go.statusline
	end

	vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(tabpage) } })
end

---@param result AtlasDiffV2Result
local function open_command(result)
	-- TODO: Test me better
	vim.cmd.tabnew()
	local tabpage = vim.api.nvim_get_current_tabpage()

	local opened, err = pcall(function()
		vim.bo.bufhidden = "wipe"
		vim.bo.buflisted = false
		vim.wo.statusline = vim.go.statusline
		vim.wo.statuscolumn = vim.go.statuscolumn
		vim.wo.winbar = vim.go.winbar

		vim.cmd.tcd(vim.fn.fnameescape(result.root))
		vim.api.nvim_cmd({
			cmd = result.options.open_cmd,
			args = { result.base_revision .. "..." .. result.head_revision },
		}, {})
	end)

	if not opened or vim.api.nvim_get_current_tabpage() ~= tabpage then
		if vim.api.nvim_tabpage_is_valid(tabpage) then
			close_tab(tabpage)
		end
	end

	if not opened then
		error(err, 0)
	end

	result.release()
end

---@param session AtlasDiffV2Session
local function close(session)
	if session.closed then
		return
	end

	session.closed = true

	if session.group then
		vim.api.nvim_del_augroup_by_id(session.group)
	end

	session.statusline:dispose()
	if vim.api.nvim_tabpage_is_valid(session.view.tabpage) then
		close_tab(session.view.tabpage)
	end
	session.renderer.dispose(session.view)

	if session.commits then
		commits.dispose(session.commits)
	end
	if session.explorer then
		explorer.dispose(session.explorer)
	end

	session.data.release()
end

---@param session AtlasDiffV2Session
---@param file AtlasDiffV2File
local function select_file(session, file)
	if session.closed then
		return
	end

	explorer.reveal(session.explorer, file)
end

---@param session AtlasDiffV2Session
---@param direction 1|-1
---@param unreviewed_only boolean|nil
local function navigate_file(session, direction, unreviewed_only)
	local files = session.explorer.files
	if #files == 0 then
		return
	end

	local position = explorer.current_index(session.explorer) or 1
	local steps = unreviewed_only and #files - 1 or 1

	for offset = 1, steps do
		local file = files[((position - 1 + direction * offset) % #files) + 1]
		if not unreviewed_only or not session.reviewed_files[file.path] then
			select_file(session, file)
			return
		end
	end

	session.statusline:notify("info", "No other unreviewed files")
end

---@param session AtlasDiffV2Session
local function find_file(session)
	picker.select({
		title = "Changed files",
		items = session.explorer.files,
		initial_index = explorer.current_index(session.explorer),
		format_item = function(file)
			return file.path
		end,
		on_select = function(file)
			if file then
				select_file(session, file)
			end
		end,
	})
end

---@param session AtlasDiffV2Session
local function focus_explorer(session)
	if not session.explorer.win then
		local win = explorer.toggle(session.explorer)
		session.statusline:attach(win)
	end

	vim.api.nvim_set_current_win(session.explorer.win)
end

---@param session AtlasDiffV2Session
local function toggle_explorer(session)
	if session.explorer.win then
		commits.close(session.commits)
	end

	local win = explorer.toggle(session.explorer)
	if win then
		session.statusline:attach(win)
		if session.commits.shown then
			local commits_win = commits.open(session.commits, win)
			session.statusline:attach(commits_win)
		end
	end
end

---@param session AtlasDiffV2Session
local function toggle_commits(session)
	if session.commits.win then
		session.commits.shown = false
		commits.close(session.commits)
		return
	end

	if not session.explorer.win and #session.commits.items > 0 then
		local win = explorer.toggle(session.explorer)
		session.statusline:attach(win)
	end

	local win, err = commits.open(session.commits, session.explorer.win)
	if not win then
		session.statusline:notify("info", err)
		return
	end

	session.commits.shown = true
	session.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param session AtlasDiffV2Session
local function setup_autocmds(session)
	local view = session.view
	session.group = vim.api.nvim_create_augroup("AtlasDiffV2" .. view.tabpage, { clear = true })

	vim.api.nvim_create_autocmd("VimResized", {
		group = session.group,
		callback = function()
			explorer.resize(session.explorer)
			commits.resize(session.commits, session.explorer.win)
		end,
	})

	vim.api.nvim_create_autocmd("TabClosed", {
		group = session.group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				close(session)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.group,
		callback = function(event)
			local win = tonumber(event.match)
			if win == view.right.win or (view.left and win == view.left.win) then
				vim.schedule(function()
					close(session)
				end)
			elseif not session.explorer.win and session.commits.win then
				commits.close(session.commits)
			end
		end,
	})
end

---@param session AtlasDiffV2Session
---@param module string
local function open_view(session, module)
	local result = session.data
	---@type AtlasDiffV2Renderer
	local renderer
	local view_opened, view = pcall(function()
		renderer = require(module)
		return renderer.open(result)
	end)

	if not view_opened then
		if result.options.open_cmd == "AtlasDiff" then
			error(view, 0)
		end

		local command = result.options.open_cmd
		logger.logwarn("diff.open fallback", {
			command = command,
			kind = result.kind,
			provider = result.pr and result.pr.provider,
			repo = result.pr and result.pr.repo_full_name,
			pr_id = result.pr and result.pr.id,
			root = result.root,
			base = result.base_revision,
			head = result.head_revision,
			error = tostring(view),
		})
		notify.warn(command .. " failed to open. Opening Atlas instead.", { vim_notify = true })

		result.options.open_cmd = "AtlasDiff"
		renderer = atlas
		view = renderer.open(result)
	end

	session.renderer = renderer
	session.view = view
end

---@param session AtlasDiffV2Session
local function setup_ui(session)
	local result = session.data
	local view = session.view
	local explorer_options = result.options.explorer
	---@cast explorer_options AtlasPullsDiffExplorerConfig

	vim.cmd.tcd(vim.fn.fnameescape(result.root))

	session.commits = commits.create(result.commits, explorer_options.show_commits)
	session.explorer = explorer.create({
		files = result.files,
		options = explorer_options,
		reviewed_files = result.review and session.reviewed_files,
		review_data = result.review and result.review.data,
		notes = result.notes and result.notes.items,
		on_select = function(file)
			select_file(session, file)
		end,
	})

	if session.commits.shown and session.explorer.win then
		commits.open(session.commits, session.explorer.win)
	end

	setup_autocmds(session)
	keymaps.setup(session, {
		close = function()
			close(session)
		end,
		toggle_explorer = function()
			toggle_explorer(session)
		end,
		toggle_commits = function()
			toggle_commits(session)
		end,
		navigate_file = function(direction, unreviewed_only)
			navigate_file(session, direction, unreviewed_only)
		end,
		find_file = function()
			find_file(session)
		end,
		focus_explorer = function()
			focus_explorer(session)
		end,
	})

	if session.explorer.files[1] then
		select_file(session, session.explorer.files[1])
	end

	diff_statusline.update(session)
	for _, pane in pairs({ view.left, view.right, session.explorer, session.commits }) do
		session.statusline:attach(pane.win)
	end

	local focus_win = explorer_options.initial_focus == "explorer" and session.explorer.win or view.right.win
	vim.api.nvim_set_current_win(focus_win)
end

---@param result AtlasDiffV2Result
---@return AtlasDiffV2Session|nil
function M.open(result)
	local module = renderers[result.options.open_cmd]
	if not module then
		open_command(result)
		return
	end

	local review_context = result.review and result.review.context
	local session = {
		data = result,
		statusline = statusline.new(),
		reviewed_files = vim.deepcopy(review_context and review_context.reviewed_files or {}),
		closed = false,
	}
	---@cast session AtlasDiffV2Session

	open_view(session, module)

	local opened, err = pcall(setup_ui, session)
	if not opened then
		close(session)
		error(err, 0)
	end

	return session
end

return M
