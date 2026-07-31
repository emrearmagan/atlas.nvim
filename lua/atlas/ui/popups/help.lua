local M = {}

local utils = require("atlas.ui.shared.utils")

---@class AtlasHelpKeyItem
---@field key string|string[]
---@field desc string
---@field callback? function|string
---@field mode? string|string[]
---@field opts? table
---@field hidden? boolean
---@field index? number

---@class AtlasHelpCommandItem
---@field name string
---@field desc string
---@field callback? function|string
---@field opts? table
---@field hidden? boolean
---@field index? number

---@class AtlasHelpGroupOpts
---@field buffer integer
---@field index? number
---@field add_to_registry? boolean

---@class AtlasHelpToggleOpts
---@field buffer? integer

local state = {
	buffers = {},
	ui = {
		visible = false,
		win_id = nil,
		buf_id = nil,
		target_bufnr = nil,
		autocmds = {},
	},
}

---@param bufnr integer
local function ensure_state(bufnr)
	if not state.buffers[bufnr] then
		state.buffers[bufnr] = {
			keys = {},
			commands = {},
			group_opts = {},
		}

		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = bufnr,
			callback = function()
				state.buffers[bufnr] = nil
			end,
			once = true,
		})
	end
	return state.buffers[bufnr]
end

local DEFAULT_INDEX = 100
local KEY_SEPARATOR = " / "
local ITEM_MARKER = " ▸ "
local MAX_COLUMNS = 4

---@param value string
---@return integer
local function display_width(value)
	return vim.fn.strdisplaywidth(value)
end

---@param opts AtlasHelpGroupOpts?
---@param source string
---@return integer
local function require_buffer(opts, source)
	local bufnr = opts and opts.buffer
	if not bufnr or type(bufnr) ~= "number" then
		error(source .. ": opts.buffer is required")
	end
	return bufnr
end

---@param key string|string[]
---@return string[]
local function normalize_keys(key)
	if type(key) == "table" then
		return key
	end
	return { key }
end

---@param list table[]
---@param field string
---@param value string
local function remove_existing_entry(list, field, value)
	for i, existing in ipairs(list) do
		if existing[field] == value then
			table.remove(list, i)
			return
		end
	end
end

---@param group string The name of the group
---@param items AtlasHelpKeyItem[]
---@param opts AtlasHelpGroupOpts
function M.register(group, items, opts)
	local bufnr = require_buffer(opts, "help.register")

	local bstate = ensure_state(bufnr)
	if not bstate.keys[group] then
		bstate.keys[group] = {}
		bstate.group_opts[group] = {}
	end

	if opts.index then
		bstate.group_opts[group].index = opts.index
	end

	for _, item in ipairs(items) do
		local mode = item.mode or "n"
		local key_opts = item.opts or {}
		key_opts.buffer = bufnr
		key_opts.desc = item.desc

		local keys = normalize_keys(item.key)

		if item.callback then
			for _, k in ipairs(keys) do
				vim.keymap.set(mode, k, item.callback, key_opts)
			end
		end

		if not item.hidden then
			local display_key = table.concat(keys, KEY_SEPARATOR)
			remove_existing_entry(bstate.keys[group], "key", display_key)

			table.insert(bstate.keys[group], {
				key = display_key,
				desc = item.desc,
				mode = mode,
				index = item.index or DEFAULT_INDEX,
			})
		end
	end
end

---@param group string The name of the group
---@param items AtlasHelpCommandItem[]
---@param opts AtlasHelpGroupOpts
function M.register_command(group, items, opts)
	local bufnr = require_buffer(opts, "help.register_command")

	local bstate = ensure_state(bufnr)
	if not bstate.commands[group] then
		bstate.commands[group] = {}
		bstate.group_opts[group] = {}
	end

	if opts.index then
		bstate.group_opts[group].index = opts.index
	end

	for _, item in ipairs(items) do
		local cmd_opts = item.opts or {}
		cmd_opts.desc = item.desc

		if item.callback then
			vim.api.nvim_buf_create_user_command(bufnr, item.name, item.callback, cmd_opts)
		end

		if not item.hidden then
			remove_existing_entry(bstate.commands[group], "name", item.name)

			table.insert(bstate.commands[group], {
				name = item.name,
				desc = item.desc,
				index = item.index or DEFAULT_INDEX,
			})
		end
	end
end

---@param group string The name of the group
---@param items { key: string|string[], mode?: string|string[] }[]
---@param opts AtlasHelpGroupOpts
function M.remove(group, items, opts)
	local bufnr = require_buffer(opts, "help.remove")
	local bstate = state.buffers[bufnr]
	if not bstate or not bstate.keys[group] then
		return
	end

	for _, item in ipairs(items) do
		local mode = item.mode or "n"
		local keys = normalize_keys(item.key)

		for _, key in ipairs(keys) do
			pcall(vim.keymap.del, mode, key, { buffer = bufnr })
		end

		local display_key = table.concat(keys, KEY_SEPARATOR)
		remove_existing_entry(bstate.keys[group], "key", display_key)
	end

	if #bstate.keys[group] == 0 then
		bstate.keys[group] = nil
		if not bstate.commands[group] then
			bstate.group_opts[group] = nil
		end
	end
end

---@param bstate table
---@param group_name string
---@return number
local function group_index(bstate, group_name)
	local opts = bstate.group_opts[group_name]
	return (opts and opts.index) or DEFAULT_INDEX
end

---@param group table
---@param item table
---@return string
local function group_item_left(group, item)
	return group.is_cmd and item.name or item.key
end

---@param bstate table
---@return table[]
local function collect_all_groups(bstate)
	local all_groups = {}

	for group_name, items in pairs(bstate.keys) do
		table.insert(all_groups, {
			name = group_name,
			items = items,
			is_cmd = false,
			index = group_index(bstate, group_name),
		})
	end

	for group_name, items in pairs(bstate.commands) do
		table.insert(all_groups, {
			name = group_name,
			items = items,
			is_cmd = true,
			index = group_index(bstate, group_name),
		})
	end

	table.sort(all_groups, function(a, b)
		if a.index == b.index then
			return a.name < b.name
		end
		return a.index < b.index
	end)

	return all_groups
end

---@param all_groups table[]
---@return table[]
local function collect_valid_groups(all_groups)
	local valid_groups = {}

	for _, group in ipairs(all_groups) do
		if #group.items > 0 then
			table.sort(group.items, function(a, b)
				if a.index == b.index then
					return group_item_left(group, a) < group_item_left(group, b)
				end
				return a.index < b.index
			end)
			table.insert(valid_groups, group)
		end
	end

	return valid_groups
end

---@param valid_groups table[]
---@return table[]
local function build_render_items(valid_groups)
	local render_items = {}

	for i, group in ipairs(valid_groups) do
		table.insert(render_items, { type = "header", text = group.name })
		for item_index, item in ipairs(group.items) do
			table.insert(render_items, {
				type = "item",
				left = group_item_left(group, item),
				right = item.desc,
				group_index = i,
				item_index = item_index,
			})
		end

		if i < #valid_groups then
			table.insert(render_items, { type = "empty" })
		end
	end

	return render_items
end

---@param render_items table[]
---@param num_cols integer
---@return table<integer, table<integer, integer>>
local function column_key_widths(render_items, num_cols)
	local widths = {}
	for _, item in ipairs(render_items) do
		if item.type == "item" then
			local column = ((item.item_index - 1) % num_cols) + 1
			widths[item.group_index] = widths[item.group_index] or {}
			widths[item.group_index][column] = math.max(widths[item.group_index][column] or 0, display_width(item.left))
		end
	end
	return widths
end

---@param render_items table[]
---@param max_width integer
---@return integer num_cols
---@return integer col_width
---@return table<integer, table<integer, integer>> key_widths
local function columns_for(render_items, max_width)
	for num_cols = MAX_COLUMNS, 2, -1 do
		local col_width = math.max(1, math.floor(max_width / num_cols))
		local key_widths = column_key_widths(render_items, num_cols)
		local fits = true
		for _, item in ipairs(render_items) do
			if item.type == "item" then
				local column = ((item.item_index - 1) % num_cols) + 1
				local key_width = key_widths[item.group_index][column]
				local item_width = 2 + key_width + display_width(ITEM_MARKER .. item.right)
				if item_width > col_width then
					fits = false
					break
				end
			end
		end
		if fits then
			return num_cols, col_width, key_widths
		end
	end
	return 1, math.max(1, max_width), column_key_widths(render_items, 1)
end

---@param highlights table[]
---@param group string
---@param line integer
---@param col_start integer
---@param col_end integer
local function add_highlight(highlights, group, line, col_start, col_end)
	table.insert(highlights, {
		group = group,
		line = line,
		col_start = col_start,
		col_end = col_end,
	})
end

local function get_layout(bufnr, max_width)
	local bstate = state.buffers[bufnr]
	if not bstate then
		return { lines = {}, highlights = {}, height = 0 }
	end

	local valid_groups = collect_valid_groups(collect_all_groups(bstate))
	if #valid_groups == 0 then
		return { lines = { "  No bindings registered  " }, highlights = {}, height = 1 }
	end

	local lines = { "" }
	local highlights = {}
	local height = 1

	local render_items = build_render_items(valid_groups)
	local num_cols, col_width, key_widths = columns_for(render_items, max_width)

	local current_line = ""
	local line_idx = 1
	local col_idx = 0

	local function flush_line()
		if current_line ~= "" then
			table.insert(lines, current_line)
			height = height + 1
			line_idx = line_idx + 1
			current_line = ""
			col_idx = 0
		end
	end

	local function add_empty_line()
		table.insert(lines, "")
		height = height + 1
		line_idx = line_idx + 1
		col_idx = 0
	end

	for _, render_item in ipairs(render_items) do
		if render_item.type == "empty" then
			flush_line()
			add_empty_line()
		elseif render_item.type == "header" then
			if current_line ~= "" then
				flush_line()
			end

			local txt = render_item.text
			add_highlight(highlights, "Title", line_idx, 2, 2 + #txt)
			current_line = "  " .. txt
			flush_line()
		else
			if col_idx >= num_cols then
				flush_line()
			end

			local column = col_idx + 1
			local max_left = key_widths[render_item.group_index][column]
			local content_width = math.max(1, col_width - 2)
			local marker_width = display_width(ITEM_MARKER)
			local left_limit = math.max(1, content_width - marker_width - 1)
			local left_str = render_item.left
			if display_width(left_str) > left_limit then
				left_str = utils.truncate(left_str, left_limit)
			end
			local left_width = display_width(left_str)
			local aligned_left_width = math.max(left_width, math.min(max_left, left_limit))
			local right_pad = aligned_left_width - left_width
			local padded_left = left_str .. string.rep(" ", right_pad)

			local description_width = content_width - aligned_left_width - marker_width
			local right_str = ""
			if description_width > 0 then
				right_str = ITEM_MARKER .. utils.truncate(render_item.right, description_width)
			end
			local display_str = padded_left .. right_str
			local pad_len = math.max(0, content_width - display_width(display_str))

			local start_col = #current_line + 2
			add_highlight(highlights, "Special", line_idx, start_col, start_col + #left_str)
			if right_str ~= "" then
				add_highlight(
					highlights,
					"Comment",
					line_idx,
					start_col + #padded_left,
					start_col + #padded_left + #right_str
				)
			end

			current_line = current_line .. "  " .. padded_left .. right_str .. string.rep(" ", pad_len)
			col_idx = col_idx + 1
		end
	end

	flush_line()
	if lines[#lines] ~= "" then
		add_empty_line()
	end

	return { lines = lines, highlights = highlights, height = height }
end

local function cleanup_ui()
	if state.ui.win_id and vim.api.nvim_win_is_valid(state.ui.win_id) then
		vim.api.nvim_win_close(state.ui.win_id, true)
	end
	if state.ui.buf_id and vim.api.nvim_buf_is_valid(state.ui.buf_id) then
		vim.api.nvim_buf_delete(state.ui.buf_id, { force = true })
	end

	for _, id in ipairs(state.ui.autocmds) do
		pcall(vim.api.nvim_del_autocmd, id)
	end

	if state.ui.on_key_ns then
		vim.on_key(nil, state.ui.on_key_ns)
	end

	state.ui.visible = false
	state.ui.win_id = nil
	state.ui.buf_id = nil
	state.ui.target_bufnr = nil
	state.ui.autocmds = {}
	state.ui.on_key_ns = nil
end

---@return boolean
function M.is_open()
	return state.ui.visible
end

---@param opts? AtlasHelpToggleOpts
function M.show(opts)
	opts = opts or {}
	local bufnr = opts.buffer or vim.api.nvim_get_current_buf()

	if state.ui.visible then
		cleanup_ui()
		return
	end

	local max_width = vim.o.columns
	local layout = get_layout(bufnr, max_width)
	if layout.height == 0 then
		return
	end

	local buf_id = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, layout.lines)

	local ns_id = vim.api.nvim_create_namespace("atlas_help_ns")
	for _, hl in ipairs(layout.highlights) do
		vim.api.nvim_buf_set_extmark(buf_id, ns_id, hl.line, hl.col_start, {
			end_col = hl.col_end,
			hl_group = hl.group,
		})
	end

	local win_id = vim.api.nvim_open_win(buf_id, false, {
		relative = "editor",
		width = max_width,
		height = layout.height,
		col = 0,
		row = vim.o.lines - layout.height,
		style = "minimal",
		border = "none",
		zindex = 250,
		focusable = false,
	})

	vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat", { win = win_id })
	vim.api.nvim_set_option_value("diff", false, { win = win_id })
	vim.api.nvim_set_option_value("scrollbind", false, { win = win_id })
	vim.api.nvim_set_option_value("cursorbind", false, { win = win_id })

	state.ui.visible = true
	state.ui.win_id = win_id
	state.ui.buf_id = buf_id
	state.ui.target_bufnr = bufnr

	vim.bo[buf_id].modifiable = false
	vim.keymap.set("n", "q", cleanup_ui, { buffer = buf_id, nowait = true, silent = true })
	vim.keymap.set("n", "<ESC>", cleanup_ui, { buffer = buf_id, nowait = true, silent = true })

	local ns = vim.api.nvim_create_namespace("atlas_help_autoclose")
	vim.on_key(function(_key)
		if not state.ui.visible then
			return
		end
		vim.schedule(cleanup_ui)
	end, ns)

	state.ui.on_key_ns = ns

	local group = vim.api.nvim_create_augroup("AtlasHelpUI", { clear = true })
	local au_id1 = vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
		group = group,
		callback = function()
			if vim.api.nvim_get_current_win() ~= state.ui.win_id then
				cleanup_ui()
			end
		end,
	})
	table.insert(state.ui.autocmds, au_id1)
end

---@param opts? AtlasHelpToggleOpts
function M.toggle(opts)
	if state.ui.visible then
		cleanup_ui()
	else
		M.show(opts)
	end
end

return M
