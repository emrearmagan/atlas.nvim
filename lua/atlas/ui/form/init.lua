local M = {}

local completion = require("atlas.completion")
local form_keymaps = require("atlas.ui.form.keymaps")
local renderer = require("atlas.ui.form.renderer")
local spinner = require("atlas.ui.components.spinner")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

---@class AtlasForm
---@field tab integer
---@field source_tab integer
---@field source_win integer
---@field editor_buf integer
---@field editor_win integer
---@field meta_buf integer
---@field meta_win integer
---@field opts AtlasFormOpenOpts
---@field meta_rows AtlasFormMetaRow[]
---@field meta_spinner SpinnerInstance
---@field augroup integer
---@field closed boolean
---@field statusline AtlasStatusline

---@class AtlasFormOpenOpts
---@field header string|nil
---@field initial_title string
---@field initial_body string
---@field is_modified (fun(form: AtlasForm): boolean)|nil
---@field meta fun(form: AtlasForm): AtlasFormMetaRow[]
---@field submit fun(form: AtlasForm)
---@field close (fun(form: AtlasForm))|nil
---@field on_closed (fun(form: AtlasForm))|nil
---@field keymaps AtlasFormKeymap[]|nil
---@field completion { context: AtlasCompletionContext, sources?: string[] }|nil

---@param form AtlasForm
function M.close(form)
	if form.closed then
		return
	end
	form.closed = true
	form.meta_spinner:stop()
	form.statusline:dispose()
	local return_to_source = vim.api.nvim_get_current_tabpage() == form.tab

	vim.api.nvim_del_augroup_by_id(form.augroup)
	if utils.tab.valid(form.tab) then
		local tab_number = vim.api.nvim_tabpage_get_number(form.tab)
		pcall(vim.cmd.tabclose, { count = tab_number, bang = true })
	end
	utils.buffer.delete(form.editor_buf)
	utils.buffer.delete(form.meta_buf)

	if return_to_source and utils.tab.valid(form.source_tab) then
		vim.api.nvim_set_current_tabpage(form.source_tab)
		if utils.window.valid(form.source_win) then
			vim.api.nvim_set_current_win(form.source_win)
		end
	end
	if form.opts.on_closed then
		form.opts.on_closed(form)
	end
end

---@param win integer
local function configure_window(win)
	local options = vim.wo[win]
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.foldcolumn = "0"
	options.statuscolumn = ""
	options.cursorline = false
	options.foldenable = false
	options.wrap = true
	options.winfixheight = false
	options.winbar = ""
end

---@param form AtlasForm
local function render_statusline(form)
	local modified = form.opts.is_modified and form.opts.is_modified(form)
	local items = form_keymaps.statusline_items(form.opts)
	items[#items + 1] = { text = modified and "Modified" or "", hl_group = "AtlasFooterWarning", align = "right" }
	form.statusline:set_items(items)
end

---@param form AtlasForm
local function setup_autocmds(form)
	local title_deleted = false
	vim.api.nvim_buf_attach(form.editor_buf, false, {
		on_lines = function(_, _, _, first, _, new_last)
			if first == 0 then
				title_deleted = new_last == 0
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = form.augroup,
		buffer = form.editor_buf,
		callback = function()
			if title_deleted or vim.api.nvim_buf_line_count(form.editor_buf) == 1 then
				local row = title_deleted and 0 or 1
				vim.cmd("silent! undojoin")
				vim.api.nvim_buf_set_lines(form.editor_buf, row, row, false, { "" })
				vim.api.nvim_win_set_cursor(form.editor_win, { row + 1, 0 })
			end
			render_statusline(form)
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = form.augroup,
		callback = function()
			renderer.render_meta(form)
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = form.augroup,
		callback = function()
			if not utils.tab.valid(form.tab) then
				M.close(form)
			end
		end,
	})
	local close = vim.schedule_wrap(function()
		M.close(form)
	end)
	for _, buf in ipairs({ form.editor_buf, form.meta_buf }) do
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = form.augroup,
			buffer = buf,
			once = true,
			callback = close,
		})
	end
	vim.api.nvim_create_autocmd("WinClosed", {
		group = form.augroup,
		pattern = { tostring(form.editor_win), tostring(form.meta_win) },
		once = true,
		callback = close,
	})
end

---@param opts AtlasFormOpenOpts
---@return AtlasForm
function M.open(opts)
	local source_tab = vim.api.nvim_get_current_tabpage()
	local source_win = vim.api.nvim_get_current_win()
	local editor_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[editor_buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_name(editor_buf, string.format("atlas://form/%d/form.md", editor_buf))
	vim.bo[editor_buf].filetype = "markdown"
	vim.cmd("tab sbuffer " .. editor_buf)
	local editor_win = vim.api.nvim_get_current_win()
	local meta_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[meta_buf].bufhidden = "wipe"
	vim.bo[meta_buf].modifiable = false
	vim.bo[meta_buf].undolevels = -1
	vim.api.nvim_buf_set_name(meta_buf, string.format("atlas://form/%d/meta", editor_buf))
	local meta_win = vim.api.nvim_open_win(meta_buf, false, { split = "above", win = editor_win, height = 1 })

	---@type AtlasForm
	local form = {
		tab = vim.api.nvim_get_current_tabpage(),
		source_tab = source_tab,
		source_win = source_win,
		editor_win = editor_win,
		editor_buf = editor_buf,
		meta_buf = meta_buf,
		meta_win = meta_win,
		opts = opts,
		meta_rows = {},
		meta_spinner = spinner.create(),
		augroup = vim.api.nvim_create_augroup("AtlasForm" .. editor_buf, { clear = true }),
		closed = false,
		statusline = statusline.new({ show_version = true }),
	}
	form.meta_spinner.on_tick = function()
		renderer.render_meta(form)
	end
	M.set_content(form, { title = opts.initial_title, body = opts.initial_body })
	configure_window(form.editor_win)
	configure_window(form.meta_win)
	vim.wo[form.meta_win].winbar = (opts.header or "Details"):gsub("%%", "%%%%")
	vim.wo[form.meta_win].winfixheight = true
	vim.wo[form.meta_win].wrap = false
	form.statusline:attach(form.editor_win)
	form.statusline:attach(form.meta_win)

	M.render_meta(form)
	form_keymaps.setup(form, opts.close or M.close)
	setup_autocmds(form)
	if opts.completion then
		completion.attach(editor_buf, {
			context = opts.completion.context,
			sources = opts.completion.sources,
			enabled = function()
				return vim.api.nvim_win_get_cursor(0)[1] > 1
			end,
		})
	end

	vim.api.nvim_win_set_cursor(form.editor_win, { 1, #opts.initial_title })
	return form
end

---@param form AtlasForm
function M.render_meta(form)
	if form.closed then
		return
	end
	form.meta_rows = form.opts.meta(form)
	local loading = false
	for _, row in ipairs(form.meta_rows) do
		for _, field in ipairs(row) do
			loading = loading or field.loading == true
		end
	end
	if loading then
		form.meta_spinner:start()
	else
		form.meta_spinner:stop()
	end
	renderer.render_meta(form)
	render_statusline(form)
end

---@param form AtlasForm
---@return { title: string, body: string }
function M.get_content(form)
	if not utils.buffer.valid(form.editor_buf) then
		return { title = "", body = "" }
	end
	local lines = vim.api.nvim_buf_get_lines(form.editor_buf, 0, -1, false)
	return { title = lines[1], body = table.concat(lines, "\n", 2) }
end

---@param form AtlasForm
---@param content { title?: string, body?: string }
---@return boolean
function M.set_content(form, content)
	if not utils.buffer.valid(form.editor_buf) then
		return false
	end
	local modifiable = vim.bo[form.editor_buf].modifiable
	vim.bo[form.editor_buf].modifiable = true
	if content.title ~= nil then
		vim.api.nvim_buf_set_lines(form.editor_buf, 0, 1, false, { content.title })
	end
	if content.body ~= nil then
		vim.api.nvim_buf_set_lines(form.editor_buf, 1, -1, false, vim.split(content.body, "\n", { plain = true }))
	end
	vim.bo[form.editor_buf].modifiable = modifiable
	render_statusline(form)
	return true
end

return M
