local notify = require("atlas.core.notify")
local info = require("atlas.ui.popups.info")
local utils = require("atlas.ui.shared.utils")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.commits")

local function render(state)
	local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
	local width = vim.api.nvim_win_get_width(state.win)
	local lines = { string.format("Commits (%d)", #state.items) }
	local highlights = { { 0, 0, #lines[1], "AtlasLogInfo" } }

	for _, commit in ipairs(state.items) do
		local hash = (commit.short_hash or commit.hash):sub(1, 8)
		local message = commit.message:match("[^\r\n]*")
		local prefix = hash .. " "

		lines[#lines + 1] = prefix
			.. utils.truncate(vim.fn.strtrans(message), math.max(1, width - vim.fn.strdisplaywidth(prefix)))
		highlights[#highlights + 1] = { #lines - 1, 0, #hash, "AtlasTextMuted" }
	end

	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, highlight[1], highlight[2], {
			end_col = highlight[3],
			hl_group = highlight[4],
		})
	end

	view.lnum = state.cursor_row
	vim.api.nvim_win_call(state.win, function()
		vim.fn.winrestview(view)
	end)
end

---@param items PullsCommit[]
---@param shown boolean
---@return { buf: integer, win?: integer, shown: boolean, items: PullsCommit[], cursor_row: integer, group: integer }
function M.create(items, shown)
	local buf = vim.api.nvim_create_buf(false, true)
	local state = {
		buf = buf,
		shown = shown,
		items = items,
		cursor_row = 2,
		group = vim.api.nvim_create_augroup("AtlasDiffCommits" .. buf, { clear = true }),
	}

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas-ui.diff-commits"
	vim.bo[buf].modifiable = false

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = state.group,
		buffer = buf,
		callback = function()
			state.cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
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
				state.cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
				render(state)
			end
		end,
	})

	return state
end

---@param parent_win integer|nil
function M.resize(state, parent_win)
	if state.win and parent_win then
		local height = vim.api.nvim_win_get_height(parent_win) + vim.api.nvim_win_get_height(state.win) + 1
		vim.api.nvim_win_set_height(state.win, math.max(2, math.floor(height * 0.2)))
	end
end

---@param parent_win integer
---@return integer|nil win
---@return string|nil err
function M.open(state, parent_win)
	if #state.items == 0 then
		return nil, "No commits available"
	end

	state.win = vim.api.nvim_open_win(state.buf, false, {
		split = "below",
		win = parent_win,
		height = math.max(2, math.floor(vim.api.nvim_win_get_height(parent_win) * 0.2)),
	})

	local options = vim.wo[state.win][0]
	options.winfixwidth = true
	options.winfixheight = true
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

	render(state)
	return state.win
end

function M.close(state)
	if state.win then
		state.cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
		vim.api.nvim_win_close(state.win, true)
	end
end

---@return PullsCommit|nil
function M.current(state)
	local row = state.win and vim.api.nvim_win_get_cursor(state.win)[1] or state.cursor_row
	return state.items[row - 1]
end

function M.copy_hash(state)
	local commit = M.current(state)
	if not commit then
		return
	end

	vim.fn.setreg("+", commit.hash)
	notify.success("Copied commit SHA")
end

function M.open_in_browser(state)
	local commit = M.current(state)
	if not commit then
		return
	end

	if commit.html_url and commit.html_url ~= "" then
		vim.ui.open(commit.html_url)
	else
		notify.warn("No URL available for this commit")
	end
end

---@param commit PullsCommit
---@return { title: string, lines: string[], filetype: string }
function M.preview(commit)
	local lines = vim.split(commit.message:gsub("\r\n", "\n"), "\n", { plain = true })
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end

	local author = commit.author_nickname
	if not author or author == "" then
		author = commit.author_name
	end
	vim.list_extend(lines, {
		"",
		"Author: " .. author,
		"Date: " .. utils.format_date(commit.date),
		"Commit: " .. commit.hash,
	})

	return {
		title = " Commit " .. (commit.short_hash or commit.hash):sub(1, 8) .. " ",
		lines = lines,
		filetype = "markdown",
	}
end

function M.show_details(state)
	info.toggle({
		source_win = state.win,
		content = function(line)
			local commit = state.items[line - 1]
			if commit then
				return M.preview(commit)
			end
		end,
	})
end

function M.dispose(state)
	M.close(state)
	vim.api.nvim_del_augroup_by_id(state.group)

	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

return M
