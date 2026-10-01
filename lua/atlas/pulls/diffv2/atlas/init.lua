local keymaps = require("atlas.pulls.diffv2.atlas.keymaps")

local function dispose(view)
	local buf = view.right.buf
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

local function open()
	vim.cmd.tabnew()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local view = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		right = { buf = buf, win = win },
	}

	local opened, err = pcall(function()
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].buflisted = false
		vim.bo[buf].swapfile = false
		vim.bo[buf].modifiable = false
		vim.wo[win].statuscolumn = vim.go.statuscolumn
		vim.wo[win].winbar = vim.go.winbar
		vim.wo[win].fillchars = "eob: "
	end)

	if not opened then
		vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(view.tabpage) } })
		dispose(view)
		error(err, 0)
	end

	return view
end

---@type AtlasDiffV2Renderer
local M = {
	open = open,
	setup_keymaps = keymaps.setup,
	dispose = dispose,
}

return M
