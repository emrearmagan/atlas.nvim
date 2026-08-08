local M = {}

local keymaps = require("atlas.core.keymaps")
local threads = require("atlas.ui.components.review_threads")
local statusline = require("atlas.ui.statusline")

local namespace = vim.api.nvim_create_namespace("atlas.review.thread_popup")

---@class AtlasReviewThreadPopupOpts
---@field nodes AtlasReviewThreadNode[]
---@field owner string
---@field title? string
---@field toggle_resolved_keys? string[]
---@field reaction_options? PullsReactionOption[]
---@field can_action fun(action: AtlasReviewCommentAction, comment: PullsComment): boolean
---@field on_action fun(action: AtlasReviewCommentAction, comment: PullsComment, close: fun())

---@class AtlasReviewThreadPopupState
---@field buf integer|nil
---@field win integer|nil
---@field owner string|nil
---@field line_map table<integer, AtlasThreadV2LineMap>

---@type AtlasReviewThreadPopupState
local state = {
	buf = nil,
	win = nil,
	owner = nil,
	line_map = {},
}

---@param buf integer|nil
---@return boolean
local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param win integer|nil
---@return boolean
local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param expected_win? integer
---@param expected_buf? integer
---@param expected_owner? string
local function close(expected_win, expected_buf, expected_owner)
	if expected_win ~= nil and state.win ~= expected_win then
		return
	end
	if expected_buf ~= nil and state.buf ~= expected_buf then
		return
	end
	if expected_owner ~= nil and state.owner ~= expected_owner then
		return
	end

	local win = state.win
	local buf = state.buf
	state.win = nil
	state.buf = nil
	state.owner = nil
	state.line_map = {}

	if valid_win(win) then
		vim.api.nvim_win_close(win, true)
	end
	if valid_buf(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

---@param owner? string
function M.close(owner)
	close(nil, nil, owner)
end

---@param owner string
---@return boolean
function M.is_open(owner)
	return state.owner == owner and valid_win(state.win) and valid_buf(state.buf)
end

---@param buf integer
---@param spans AtlasThreadV2Span[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@class AtlasReviewThreadPopupKeys
---@field close? string[]
---@field reply? string[]
---@field edit? string[]
---@field delete? string[]
---@field toggle_resolved? string[]

---@param keys string[]|nil
---@return string|nil
local function key_label(keys)
	return keys and table.concat(keys, " / ") or nil
end

---@param opts AtlasReviewThreadPopupOpts
---@param keys AtlasReviewThreadPopupKeys
---@return string[], AtlasThreadV2Span[], table<integer, AtlasThreadV2LineMap>, integer, integer, integer, integer
local function popup_content(opts, keys)
	local available_width = math.max(vim.o.columns - 4, 1)
	local width = math.min(100, available_width)
	local toggle_key = key_label(keys.toggle_resolved)
	local lines, spans, line_map = threads.render(opts.nodes, width, {
		expanded = function()
			return true
		end,
		can_action = opts.can_action,
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

	local height = math.max(1, math.min(#lines, math.max(vim.o.lines - 6, 1)))
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))
	return lines, spans, line_map, width, height, row, col
end

---@param opts AtlasReviewThreadPopupOpts
function M.open(opts)
	vim.validate({
		nodes = { opts.nodes, "table" },
		owner = { opts.owner, "string" },
		on_action = { opts.on_action, "function" },
	})

	M.close()
	local source_win = vim.api.nvim_get_current_win()
	local keys = {
		close = keymaps.resolve("ui.close"),
		reply = keymaps.resolve("pulls.review.diff.add_comment"),
		edit = keymaps.resolve("pulls.review.diff.edit_comment"),
		delete = keymaps.resolve("pulls.review.diff.delete"),
		toggle_resolved = opts.toggle_resolved_keys,
	}

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "atlas-review-thread", { buf = buf })

	---@param win? integer
	---@return table|nil
	local function render(win)
		local cursor = win and vim.api.nvim_win_get_cursor(win) or nil
		local lines, spans, line_map, width, height, row, col = popup_content(opts, keys)
		if #lines == 0 then
			return nil
		end

		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		apply_spans(buf, spans)
		state.line_map = line_map

		local config = {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
		}
		if win then
			vim.api.nvim_win_set_config(win, config)
			local cursor_row = math.min(cursor[1], #lines)
			local cursor_col = math.min(cursor[2], #(lines[cursor_row] or ""))
			vim.api.nvim_win_set_cursor(win, { cursor_row, cursor_col })
		end
		return config
	end

	local config = render()
	if not config then
		vim.api.nvim_buf_delete(buf, { force = true })
		return
	end
	config.style = "minimal"
	config.border = "rounded"
	config.title = opts.title or " Review thread "
	config.title_pos = "center"
	config.zindex = 40
	local win = vim.api.nvim_open_win(buf, true, config)
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("diff", false, { win = win })
	vim.api.nvim_set_option_value("scrollbind", false, { win = win })
	vim.api.nvim_set_option_value("cursorbind", false, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	statusline.inherit(win, source_win)

	state.buf = buf
	state.win = win
	state.owner = opts.owner

	local function close_current()
		close(win, buf, opts.owner)
	end

	---@param action_name AtlasReviewCommentAction
	local function action(action_name)
		return function()
			if not valid_win(win) or state.win ~= win or state.owner ~= opts.owner then
				return
			end
			local lnum = vim.api.nvim_win_get_cursor(win)[1]
			local entry = state.line_map[lnum]
			local comment = entry and entry.comment or nil
			if comment == nil or not opts.can_action(action_name, comment) then
				return
			end
			opts.on_action(action_name, comment, close_current)
		end
	end

	local keymap_opts = { buffer = buf, nowait = true, silent = true }
	local function map(keys_to_map, callback)
		for _, key in ipairs(keys_to_map or {}) do
			vim.keymap.set("n", key, callback, keymap_opts)
		end
	end

	map(keys.close, close_current)
	vim.keymap.set("n", "<Esc>", close_current, keymap_opts)
	map(keys.reply, action("reply"))
	map(keys.edit, action("edit"))
	map(keys.delete, action("delete"))

	local function toggle_resolved()
		if not valid_win(win) or state.win ~= win or state.owner ~= opts.owner then
			return
		end
		local entry = state.line_map[vim.api.nvim_win_get_cursor(win)[1]]
		local comment = entry and entry.comment or nil
		local action_name = comment and comment.is_task and "toggle_task" or "toggle_resolved"
		local target = action_name == "toggle_resolved" and entry and entry.thread_root or comment
		if target and opts.can_action(action_name, target) then
			opts.on_action(action_name, target, close_current)
		end
	end
	map(keys.toggle_resolved, toggle_resolved)

	local resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
		callback = function()
			vim.schedule(function()
				if state.win == win and valid_win(win) and valid_buf(buf) then
					render(win)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			pcall(vim.api.nvim_del_autocmd, resize_autocmd)
			if state.win == win then
				state.win = nil
				state.buf = nil
				state.owner = nil
				state.line_map = {}
			end
			if valid_buf(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end,
	})
end

return M
