local notify = require("atlas.core.notify")
local info = require("atlas.ui.popups.info")
local utils = require("atlas.ui.shared.utils")

---@class AtlasDiffCommits
---@field buf integer
---@field win integer|nil
---@field shown boolean
---@field items PullsCommit[]
---@field cursor_row integer
---@field group integer
local Commits = {}
Commits.__index = Commits

local namespace = vim.api.nvim_create_namespace("atlas.diff.commits")

local function render(state)
	local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
	local width = vim.api.nvim_win_get_width(state.win)
	local lines = { string.format("All commits (%d)", #state.items) }
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
---@return AtlasDiffCommits
function Commits.new(items, shown)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, string.format("Commits [%d]", vim.api.nvim_get_current_tabpage()))
	local state = setmetatable({
		buf = buf,
		shown = shown,
		items = items,
		cursor_row = 2,
		group = vim.api.nvim_create_augroup("AtlasDiffCommits" .. buf, { clear = true }),
	}, Commits)

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
function Commits:resize(parent_win)
	if self.win and parent_win then
		local height = vim.api.nvim_win_get_height(parent_win) + vim.api.nvim_win_get_height(self.win) + 1
		vim.api.nvim_win_set_height(self.win, math.max(2, math.floor(height * 0.2)))
	end
end

---@param parent_win integer
---@return integer|nil win
---@return string|nil err
function Commits:open(parent_win)
	if #self.items == 0 then
		return nil, "No commits available"
	end

	self.win = vim.api.nvim_open_win(self.buf, false, {
		split = "below",
		win = parent_win,
		height = math.max(2, math.floor(vim.api.nvim_win_get_height(parent_win) * 0.2)),
	})

	local options = vim.wo[self.win][0]
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

	render(self)
	return self.win
end

function Commits:close()
	if self.win then
		self.cursor_row = vim.api.nvim_win_get_cursor(self.win)[1]
		vim.api.nvim_win_close(self.win, true)
	end
end

---@return PullsCommit|nil
function Commits:current()
	local row = self.win and vim.api.nvim_win_get_cursor(self.win)[1] or self.cursor_row
	return self.items[row - 1]
end

function Commits:copy_hash()
	local commit = self:current()
	if not commit then
		return
	end

	vim.fn.setreg("+", commit.hash)
	notify.success("Copied commit SHA")
end

function Commits:open_in_browser()
	local commit = self:current()
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
function Commits.preview(commit)
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

function Commits:show_details()
	info.toggle({
		source_win = self.win,
		content = function(line)
			local commit = self.items[line - 1]
			if commit then
				return Commits.preview(commit)
			end
		end,
	})
end

function Commits:dispose()
	self:close()
	vim.api.nvim_del_augroup_by_id(self.group)

	if vim.api.nvim_buf_is_valid(self.buf) then
		vim.api.nvim_buf_delete(self.buf, { force = true })
	end
end

return Commits
