local M = {}

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param kind "win"|"buf"
---@param id integer|nil
local function close_target(kind, id)
	if kind == "win" then
		if valid_win(id) then
			vim.api.nvim_win_close(id, true)
		end
		return
	end

	if valid_buf(id) then
		vim.api.nvim_buf_delete(id, { force = true })
	end
end

---@param layout CreateIssueLayout
function M.close(layout)
	close_target("win", layout.desc_win)
	close_target("win", layout.meta_win)
	close_target("win", layout.title_win)
	close_target("win", layout.container_win)

	close_target("buf", layout.desc_buf)
	close_target("buf", layout.meta_buf)
	close_target("buf", layout.title_buf)
	close_target("buf", layout.container_buf)
end

---@param opts { buftype: string, modifiable: boolean, name: string, filetype?: string }
---@return integer
local function create_buffer(opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", opts.buftype, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	if opts.filetype then
		vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
	end
	vim.api.nvim_set_option_value("modifiable", opts.modifiable, { buf = buf })
	pcall(vim.api.nvim_buf_set_name, buf, opts.name)
	return buf
end

---@param opts { buffer: integer, enter: boolean, parent: integer, width: integer, height: integer, row: integer, col: integer, focusable?: boolean, wrap: boolean, winbar?: string }
---@return integer
local function open_window(opts)
	local win = vim.api.nvim_open_win(opts.buffer, opts.enter, {
		relative = "win",
		win = opts.parent,
		width = opts.width,
		height = opts.height,
		row = opts.row,
		col = opts.col,
		style = "minimal",
		border = "none",
		focusable = opts.focusable,
	})

	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("wrap", opts.wrap, { win = win })

	if opts.winbar then
		vim.api.nvim_set_option_value("winbar", opts.winbar, { win = win })
	end

	return win
end

---@param state CreateIssueState
function M.open(state)
	local width = math.max(math.floor(vim.o.columns * 0.75), 80)
	local height = math.max(math.floor(vim.o.lines * 0.75), 22)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local inner_width = width - 2
	local content_width = inner_width - 4
	local content_col = 2
	local meta_height = 3

	state.content_width = content_width

	local popup_title = " Create Issue "
	local footer = " q close | <C-s> submit | ga assignees | gl labels | gm milestone | <Tab> next field "

	state.layout.container_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.layout.container_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.layout.container_buf })

	state.layout.container_win = vim.api.nvim_open_win(state.layout.container_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		focusable = false,
		mouse = false,
		title = popup_title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})
	vim.api.nvim_set_option_value("wrap", false, { win = state.layout.container_win })

	state.layout.title_buf = create_buffer({
		buftype = "nofile",
		modifiable = true,
		name = "atlas://pulls/create_issue/title",
	})

	state.layout.meta_buf = create_buffer({
		buftype = "nofile",
		modifiable = false,
		name = "atlas://pulls/create_issue/meta",
	})

	state.layout.desc_buf = create_buffer({
		buftype = "nofile",
		modifiable = true,
		name = "atlas://pulls/create_issue/description.md",
		filetype = "markdown",
	})

	vim.api.nvim_buf_set_lines(state.layout.title_buf, 0, -1, false, { tostring(state.fields.title or "") })

	local separator = string.rep("─", inner_width)
	vim.api.nvim_buf_set_lines(state.layout.container_buf, 0, -1, false, vim.fn["repeat"]({ "" }, height))

	state.layout.title_win = open_window({
		buffer = state.layout.title_buf,
		enter = true,
		parent = state.layout.container_win,
		width = content_width,
		height = 2,
		row = 0,
		col = content_col,
		wrap = false,
		winbar = "Title",
	})

	local meta_row = 4
	state.layout.meta_win = open_window({
		buffer = state.layout.meta_buf,
		enter = false,
		parent = state.layout.container_win,
		width = content_width,
		height = meta_height,
		row = meta_row,
		col = content_col,
		focusable = false,
		wrap = false,
	})

	local desc_row = meta_row + meta_height + 1
	state.layout.desc_win = open_window({
		buffer = state.layout.desc_buf,
		enter = false,
		parent = state.layout.container_win,
		width = content_width,
		height = math.max(1, height - desc_row - 1),
		row = desc_row,
		col = content_col,
		wrap = true,
		winbar = "Description",
	})

	vim.api.nvim_buf_set_lines(state.layout.container_buf, 3, 4, false, { separator })
	vim.api.nvim_buf_set_lines(state.layout.container_buf, desc_row - 1, desc_row, false, { separator })
end

---@param state CreateIssueState
---@param actions { confirm_close: fun(), submit: fun(), pick_assignees: fun(), pick_labels: fun(), pick_milestone: fun() }
function M.setup(state, actions)
	local keymap_opts = { silent = true, nowait = true }

	local function set_keymap(buf, mode, lhs, rhs)
		vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", keymap_opts, { buffer = buf }))
	end

	local function jump_to_desc()
		if valid_win(state.layout.desc_win) then
			vim.api.nvim_set_current_win(state.layout.desc_win)
		end
	end

	local function jump_to_title()
		if valid_win(state.layout.title_win) then
			vim.api.nvim_set_current_win(state.layout.title_win)
		end
	end

	if valid_buf(state.layout.title_buf) then
		local buf = state.layout.title_buf
		set_keymap(buf, "n", "q", actions.confirm_close)
		set_keymap(buf, "n", "<CR>", jump_to_desc)
		set_keymap(buf, "n", "<Tab>", jump_to_desc)
		set_keymap(buf, "n", "<S-Tab>", jump_to_desc)
		set_keymap(buf, "n", "ga", actions.pick_assignees)
		set_keymap(buf, "n", "gl", actions.pick_labels)
		set_keymap(buf, "n", "gm", actions.pick_milestone)
		set_keymap(buf, "i", "<CR>", function()
			vim.cmd("stopinsert")
			jump_to_desc()
		end)
		set_keymap(buf, "i", "<Tab>", function()
			vim.cmd("stopinsert")
			jump_to_desc()
		end)
		set_keymap(buf, { "n", "i" }, "<C-j>", function()
			vim.cmd("stopinsert")
			jump_to_desc()
		end)
		set_keymap(buf, { "n", "i" }, "<C-s>", function()
			vim.cmd("stopinsert")
			actions.submit()
		end)
	end

	if valid_buf(state.layout.desc_buf) then
		local buf = state.layout.desc_buf
		set_keymap(buf, "n", "q", actions.confirm_close)
		set_keymap(buf, "n", "<Tab>", jump_to_title)
		set_keymap(buf, "n", "<S-Tab>", jump_to_title)
		set_keymap(buf, "n", "ga", actions.pick_assignees)
		set_keymap(buf, "n", "gl", actions.pick_labels)
		set_keymap(buf, "n", "gm", actions.pick_milestone)
		set_keymap(buf, { "n", "i" }, "<C-k>", function()
			vim.cmd("stopinsert")
			jump_to_title()
		end)
		set_keymap(buf, { "n", "i" }, "<C-s>", function()
			vim.cmd("stopinsert")
			actions.submit()
		end)
	end
end

return M
