local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local detail = require("atlas.pulls.ui.detail.state")

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@class AtlasCommitsPinState
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

---@param commit PullsCommit
---@return string[]
function M.format_commit_lines(commit)
	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	local lines = vim.split(message, "\n", { plain = true })
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	table.insert(lines, "")

	local author = (commit.author_nickname ~= "" and commit.author_nickname) or commit.author_name or "Unknown"
	table.insert(lines, "Author: " .. tostring(author))
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

	local config = {
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
		vim.api.nvim_win_set_config(pin.win, config)
	else
		pin.win = vim.api.nvim_open_win(pin.buf, false, config)
		vim.wo[pin.win].wrap = true
		vim.wo[pin.win].linebreak = true
	end
end

---@param buf integer
local function start_pin(buf)
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = detail.line_map[lnum]
	if not (entry and entry.commit) then
		return
	end

	render_pin(entry.commit)

	pin.group = vim.api.nvim_create_augroup("AtlasCommitsPinnedPreview", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = pin.group,
		buffer = buf,
		callback = function()
			local cur_win = detail.win
			if cur_win == nil or not vim.api.nvim_win_is_valid(cur_win) then
				close_pin()
				return
			end
			local cur_lnum = vim.api.nvim_win_get_cursor(cur_win)[1]
			local cur_entry = detail.line_map[cur_lnum]
			if cur_entry and cur_entry.commit then
				render_pin(cur_entry.commit)
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

---@param buf integer
---@param _refresh fun()
function M.setup(buf, _refresh)
	local items = {}
	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show full commit message (stays open while navigating)",
			opts = { nowait = true, silent = true },
			callback = function()
				if pin_active() then
					close_pin()
					return
				end
				start_pin(buf)
			end,
		})
	)
	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	close_pin()
	local items = {}
	utils.insert_if(items, remove_item("ui.show_details"))
	help.remove("Detail", items, { buffer = buf })
end

function M.close_pin()
	close_pin()
end

return M
