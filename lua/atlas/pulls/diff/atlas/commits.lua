local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_native_commits")

---@class AtlasDiffCommitsPinState
---@field win integer|nil
---@field buf integer|nil
---@field group integer|nil
---@field hash string|nil
local pin = {
	win = nil,
	buf = nil,
	group = nil,
	hash = nil,
}

local function pin_active()
	return pin.win ~= nil and vim.api.nvim_win_is_valid(pin.win)
end

local function close_pin()
	if pin.group ~= nil then
		pcall(vim.api.nvim_del_augroup_by_id, pin.group)
	end
	if pin.win ~= nil and vim.api.nvim_win_is_valid(pin.win) then
		vim.api.nvim_win_close(pin.win, true)
	end
	pin.win = nil
	pin.buf = nil
	pin.group = nil
	pin.hash = nil
end

---@param session AtlasDiffSession
function M.render(session)
	local buf = session.viewer_state.commits_panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local win = session.viewer_state.commits_panel.win
	local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)
		or session.viewer_state.explorer.width
	local lines, highlights = { "" }, {}
	local icon, icon_hl = icons.pulls("commit")
	session.viewer_state.commit_items = {}

	if #session.commits == 0 then
		table.insert(lines, "No commits")
		table.insert(highlights, { 1, 0, #lines[2], "AtlasTextMuted" })
	else
		for _, commit in ipairs(session.commits) do
			local hash = tostring(commit.short_hash or commit.hash or ""):sub(1, 8)
			local message = tostring(commit.message or ""):gsub("\r\n", "\n"):match("[^\n]+") or ""
			local prefix = string.format("%s %s ", icon, hash)
			local text = prefix .. utils.truncate(message, math.max(1, width - vim.fn.strdisplaywidth(prefix)))
			table.insert(lines, text)
			session.viewer_state.commit_items[#lines] = commit
			local icon_start = 0
			local hash_start = icon_start + #icon + 1
			table.insert(highlights, { #lines - 1, icon_start, icon_start + #icon, icon_hl })
			table.insert(highlights, { #lines - 1, hash_start, hash_start + #hash, "AtlasTextMuted" })
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
		virt_text = { { string.format("Commits (%d)", #session.commits), "AtlasLogInfo" } },
		virt_text_pos = "overlay",
	})
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, namespace, highlight[1], highlight[2], {
			end_col = highlight[3],
			hl_group = highlight[4],
		})
	end
	if win and vim.api.nvim_win_is_valid(win) and #session.commits > 0 then
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			vim.api.nvim_win_set_cursor(win, { 2, 0 })
		end
	end
end

---@param commit PullsCommit
---@return string[]
function M.format_commit_lines(commit)
	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	local lines = vim.split(message, "\n", { plain = true })
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	table.insert(lines, "")

	local author = tostring(commit.author_nickname or "")
	if author == "" then
		author = tostring(commit.author_name or "Unknown")
	end
	table.insert(lines, "Author: " .. author)
	table.insert(lines, "Date: " .. utils.format_date(commit.date))
	table.insert(lines, "Commit: " .. tostring(commit.hash or commit.short_hash or ""))
	return lines
end

---@param lines string[]
---@return integer width, integer height
local function pin_size(lines)
	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	local width = math.max(1, math.min(content_width, math.max(vim.o.columns - 4, 1)))
	local height = math.max(1, math.min(#lines, math.max(vim.o.lines - 4, 1)))
	return width, height
end

---@param commit PullsCommit
local function render_pin(commit)
	local hash = tostring(commit.hash or commit.short_hash or "")
	if pin_active() and hash == pin.hash then
		return
	end

	local lines = M.format_commit_lines(commit)
	local width, height = pin_size(lines)
	local title = string.format(" Commit %s ", tostring(commit.short_hash or commit.hash or ""):sub(1, 8))

	if not (pin.buf ~= nil and vim.api.nvim_buf_is_valid(pin.buf)) then
		pin.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[pin.buf].bufhidden = "wipe"
		vim.bo[pin.buf].swapfile = false
		vim.bo[pin.buf].filetype = "markdown"
	end

	vim.bo[pin.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pin.buf, 0, -1, false, lines)
	vim.bo[pin.buf].modifiable = false
	pin.hash = hash

	local win_config = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		focusable = false,
		title = title,
		zindex = 260,
	}

	if pin_active() then
		vim.api.nvim_win_set_config(pin.win, win_config)
	else
		pin.win = vim.api.nvim_open_win(pin.buf, false, win_config)
		vim.wo[pin.win].wrap = true
		vim.wo[pin.win].linebreak = true
	end
end

--- Shows the full commit message for the commit under the cursor. The
--- preview stays open and live-updates as the cursor moves to other commits;
--- calling this again while it is open closes it.
---@param session AtlasDiffSession
function M.show_details(session)
	local buf = session.viewer_state.commits_panel.buf
	if vim.api.nvim_get_current_buf() ~= buf then
		return
	end

	if pin_active() then
		close_pin()
		return
	end

	local commit = session.viewer_state.commit_items[vim.api.nvim_win_get_cursor(0)[1]]
	if not commit then
		return
	end

	render_pin(commit)

	pin.group = vim.api.nvim_create_augroup("AtlasDiffCommitsPinnedPreview", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = pin.group,
		buffer = buf,
		callback = function()
			if vim.api.nvim_get_current_buf() ~= buf then
				return
			end
			local cur_commit = session.viewer_state.commit_items[vim.api.nvim_win_get_cursor(0)[1]]
			if cur_commit then
				render_pin(cur_commit)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed" }, {
		group = pin.group,
		buffer = buf,
		once = true,
		callback = close_pin,
	})
end

function M.close_pin()
	close_pin()
end

return M
