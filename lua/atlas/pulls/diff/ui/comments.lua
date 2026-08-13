local M = {}

local box = require("atlas.ui.components.box")
local keymaps = require("atlas.core.keymaps")
local statusline = require("atlas.ui.statusline")
local threads = require("atlas.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_comments")
local popup_namespace = vim.api.nvim_create_namespace("atlas_diff_thread_popup")
local popup = { buf = nil, win = nil, owner = nil, line_map = {} }

---@class AtlasCommentRendererContext
---@field threads AtlasReviewThreadNode[]
---@field expanded_threads table<string, boolean>
---@field old_path string
---@field new_path string
---@field reaction_options PullsReactionOption[]|nil

---@param buf integer
---@return integer
local function buffer_width(buf)
	local wins = vim.fn.win_findbuf(buf)
	return wins[1] and vim.api.nvim_win_get_width(wins[1]) or vim.o.columns
end

---@param current AtlasDiffCurrent
function M.clear(current)
	for _, side in ipairs({ current.left, current.right }) do
		if vim.api.nvim_buf_is_valid(side.buf) then
			vim.api.nvim_buf_clear_namespace(side.buf, namespace, 0, -1)
		end
	end
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param list AtlasReviewThreadNode[]
---@return [string, string][][]
function M.thread_lines(context, buf, list)
	local width = buffer_width(buf)
	local lines, spans = threads.render(list, math.max(1, width - 4), {
		expanded = function(root)
			return threads.is_thread_expanded(root, context.expanded_threads)
		end,
		padding_x = 0,
		reaction_options = context.reaction_options,
	})
	local rendered = box.render({ { lines = lines, spans = spans } }, { width = width, padding_x = 0 })
	return utils.virtual_lines(rendered.lines, rendered.highlights)
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
---@param above_lines table<integer, boolean>
---@return table<integer, integer>
function M.render_comments(context, buf, by_line, above_lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	local sizes = {}
	local line_count = vim.api.nvim_buf_line_count(buf)
	for line, list in pairs(by_line) do
		if line >= 1 and line <= line_count then
			local virtual_lines = M.thread_lines(context, buf, list)
			sizes[line] = #virtual_lines
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				virt_lines = virtual_lines,
				virt_lines_above = above_lines[line] == true,
				virt_lines_leftcol = true,
				number_hl_group = "CursorLineNr",
				sign_text = "┃",
				sign_hl_group = "AtlasLogInfo",
				priority = 1100,
			})
		end
	end
	return sizes
end

---@param buf integer
---@param line integer
---@param count integer
---@param above boolean
function M.pad(buf, line, count, above)
	if count <= 0 then
		return
	end
	local virtual_lines = {}
	for _ = 1, count do
		virtual_lines[#virtual_lines + 1] = { { "", "Normal" } }
	end
	vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
		virt_lines = virtual_lines,
		virt_lines_above = above,
		virt_lines_leftcol = true,
		priority = 1090,
	})
end

---@param owner string|nil
function M.close_popup(owner)
	if owner and popup.owner ~= owner then
		return
	end
	local win, buf = popup.win, popup.buf
	popup = { buf = nil, win = nil, owner = nil, line_map = {} }
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

---@param owner string
---@return boolean
function M.popup_is_open(owner)
	return popup.owner == owner and popup.win ~= nil and vim.api.nvim_win_is_valid(popup.win)
end

---@param keys string[]|nil
---@return string|nil
local function key_label(keys)
	return keys and table.concat(keys, " / ") or nil
end

---@class AtlasDiffThreadPopupOptions
---@field nodes AtlasReviewThreadNode[]
---@field owner string
---@field title string|nil
---@field toggle_resolved_keys string[]|nil
---@field reaction_options PullsReactionOption[]|nil
---@field on_action fun(action: AtlasReviewThreadAction, comment: PullsComment, close: fun())

---@param opts AtlasDiffThreadPopupOptions
function M.open_popup(opts)
	M.close_popup()
	local source_win = vim.api.nvim_get_current_win()
	local keys = {
		close = keymaps.resolve("ui.close"),
		reply = keymaps.resolve("pulls.review.diff.add_comment"),
		edit = keymaps.resolve("pulls.review.diff.edit_comment"),
		delete = keymaps.resolve("pulls.review.diff.delete"),
		toggle = opts.toggle_resolved_keys,
	}
	local width = math.min(100, math.max(1, vim.o.columns - 4))
	local toggle_key = key_label(keys.toggle)
	local lines, spans, line_map = threads.render(opts.nodes, width, {
		expanded = function()
			return true
		end,
		action_keys = {
			reply = key_label(keys.reply),
			edit = key_label(keys.edit),
			delete = key_label(keys.delete),
			toggle_resolved = toggle_key,
		},
		padding_x = 1,
		toggle_resolved_key = toggle_key,
		reaction_options = opts.reaction_options,
	})
	if #lines == 0 then
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "atlas-review-thread"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, popup_namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	local height = math.min(#lines, math.max(1, vim.o.lines - 6))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title or " Review thread ",
		title_pos = "center",
		zindex = 40,
	})
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	statusline.inherit(win, source_win)
	popup = { buf = buf, win = win, owner = opts.owner, line_map = line_map }

	local function close()
		M.close_popup(opts.owner)
	end
	local function action(name)
		return function()
			local entry = popup.line_map[vim.api.nvim_win_get_cursor(win)[1]]
			if entry and entry.comment then
				opts.on_action(name, entry.comment, close)
			end
		end
	end
	local map_opts = { buffer = buf, nowait = true, silent = true }
	local function map(list, callback)
		for _, key in ipairs(list or {}) do
			vim.keymap.set("n", key, callback, map_opts)
		end
	end
	map(keys.close, close)
	vim.keymap.set("n", "<Esc>", close, map_opts)
	map(keys.reply, action("add_comment"))
	map(keys.edit, action("edit"))
	map(keys.delete, action("delete"))
	map(keys.toggle, function()
		local entry = popup.line_map[vim.api.nvim_win_get_cursor(win)[1]]
		if not entry or not entry.comment then
			return
		end
		local name = entry.comment.is_task and "toggle_task" or "toggle_resolved"
		local target = name == "toggle_resolved" and entry.thread_root or entry.comment
		opts.on_action(name, target, close)
	end)
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if popup.win == win then
				popup = { buf = nil, win = nil, owner = nil, line_map = {} }
			end
		end,
	})
end

return M
