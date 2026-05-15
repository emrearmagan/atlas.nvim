local M = {}

local footer = require("atlas.ui.components.footer")

local completion_provider_by_buf = {}

---@class AtlasMarkdownCompletionProvider
---@field trigger string|nil
---@field find_start fun(before: string, line: string, col: integer): integer|nil
---@field complete fun(base: string, line: string, col: integer): table[]|nil
---@field format_mention (fun(author: IssueUser|PullsAuthor|nil): string)|nil

---@param findstart integer
---@param base string
---@return integer|table[]
function _G.__atlas_markdown_complete(findstart, base)
	local buf = vim.api.nvim_get_current_buf()
	local provider = completion_provider_by_buf[buf]
	if type(provider) ~= "table" then
		return findstart == 1 and -2 or {}
	end

	if findstart == 1 then
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local before = line:sub(1, col)
		local start = provider.find_start(before, line, col)
		if type(start) ~= "number" then
			return -2
		end
		return start
	end

	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local items = provider.complete(tostring(base or ""), line, col)
	if type(items) ~= "table" then
		return {}
	end
	return items
end

---@class AtlasMarkdownEditorAction
---@field key string|string[]
---@field description string|nil
---@field callback fun(ctx: { buf: integer, win: integer, close: fun(), get_text: fun(): string })
---@field mode string|string[]|nil

---@class AtlasMarkdownEditorOptions
---@field key string
---@field title string|nil
---@field initial_text string|nil
---@field width_ratio number|nil
---@field height_ratio number|nil
---@field on_save fun(text: string)|nil
---@field on_cancel fun()|nil
---@field actions AtlasMarkdownEditorAction[]|nil
---@field completion AtlasMarkdownCompletionProvider|nil

---@param opts AtlasMarkdownEditorOptions
---@return integer|nil, integer|nil
function M.open(opts)
	if type(opts) ~= "table" then
		return nil, nil
	end

	local key = tostring(opts.key or "")
	if key == "" then
		footer.notify("warn", "Missing editor key")
		return nil, nil
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local name = string.format("atlas://jira/editor/%s.md", key)
	pcall(vim.api.nvim_buf_set_name, buf, name)

	local lines = vim.split(tostring(opts.initial_text or ""), "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local width_ratio = tonumber(opts.width_ratio) or 0.8
	local height_ratio = tonumber(opts.height_ratio) or 0.8
	local min_width = 80
	local min_height = 12

	local width = math.max(math.floor(vim.o.columns * width_ratio), min_width)
	local height = math.max(math.floor(vim.o.lines * height_ratio), min_height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local footer_items = { "q quit", "<C-s> save+close" }
	for _, action in ipairs(type(opts.actions) == "table" and opts.actions or {}) do
		local action_key = action and action.key or nil
		local description = action and action.description or nil
		if
			type(action_key) == "string"
			and action_key ~= ""
			and type(description) == "string"
			and description ~= ""
		then
			table.insert(footer_items, string.format("%s %s", action_key, description))
		end
	end

	local footer_text = " " .. table.concat(footer_items, " | ") .. " "

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = row,
		col = col,
		title = opts.title,
		title_pos = "center",
		footer = footer_text,
		footer_pos = "center",
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)

	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })

	local completion = opts.completion
	if completion ~= nil then
		completion_provider_by_buf[buf] = completion
		vim.api.nvim_set_option_value("completeopt", "menu,menuone,noselect,noinsert", { buf = buf })
		vim.api.nvim_set_option_value("completefunc", "v:lua.__atlas_markdown_complete", { buf = buf })

		local function open_completion_popup()
			local provider = completion_provider_by_buf[buf]
			if provider == nil then
				return
			end

			if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
				return
			end
			if vim.fn.mode() ~= "i" or vim.fn.pumvisible() == 1 then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(0)
			local cursor_row = tonumber(cursor[1]) or 1
			local cursor_col = tonumber(cursor[2]) or 0
			local line = vim.api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, false)[1] or ""
			if type(line) ~= "string" then
				return
			end

			local before = line:sub(1, cursor_col)
			local start = provider.find_start(before, line, cursor_col)
			if type(start) ~= "number" then
				return
			end

			local base = before:sub(start + 1)
			local items = provider.complete(tostring(base or ""), line, cursor_col)
			if type(items) ~= "table" or #items == 0 then
				return
			end

			vim.fn.complete(start + 1, items)
		end

		local trigger = completion.trigger
		if type(trigger) == "string" and trigger ~= "" then
			vim.keymap.set("i", trigger, function()
				local provider = completion_provider_by_buf[buf]
				if provider == nil then
					return trigger
				end
				vim.schedule(open_completion_popup)
				return trigger
			end, { buffer = buf, silent = true, nowait = true, expr = true })
		end

		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				completion_provider_by_buf[buf] = nil
			end,
		})
	end

	local function close_editor()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function get_text()
		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end

	vim.keymap.set("n", "q", function()
		if type(opts.on_cancel) == "function" then
			opts.on_cancel()
		end
		close_editor()
	end, { buffer = buf, silent = true, nowait = true })

	vim.keymap.set("n", "<Esc>", function()
		if type(opts.on_cancel) == "function" then
			opts.on_cancel()
		end
		close_editor()
	end, { buffer = buf, silent = true, nowait = true })

	local function save_and_close()
		local body = get_text()

		if type(opts.on_save) == "function" then
			opts.on_save(body)
		end

		close_editor()
	end

	vim.keymap.set("n", "<C-s>", save_and_close, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("i", "<C-s>", function()
		vim.cmd("stopinsert")
		save_and_close()
	end, { buffer = buf, silent = true, nowait = true })

	for _, action in ipairs(type(opts.actions) == "table" and opts.actions or {}) do
		if type(action) == "table" and type(action.callback) == "function" then
			local action_key = action.key
			local action_mode = action.mode or "n"
			if type(action_key) == "string" or type(action_key) == "table" then
				vim.keymap.set(action_mode, action_key, function()
					local ok, err = pcall(action.callback, {
						buf = buf,
						win = win,
						close = close_editor,
						get_text = get_text,
					})
					if not ok then
						footer.notify("error", tostring(err or "Markdown action failed"))
					end
				end, { buffer = buf, silent = true, nowait = true, desc = action.description })
			end
		end
	end

	return buf, win
end

return M
