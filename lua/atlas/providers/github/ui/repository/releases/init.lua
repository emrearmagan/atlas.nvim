local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {
	key = "releases",
	label = "Releases",
	icon = icons.pulls("tag"),
}

---@param state { buf: integer, win: integer }
local function render(state)
	utils.buffer.center_message(state.buf, state.win, "Releases coming soon")
end

---@param opts { buf: integer, win: integer }
function M.open(opts)
	local state = { buf = opts.buf, win = opts.win }
	render(state)
	local group = vim.api.nvim_create_augroup("AtlasRepositoryReleases" .. opts.buf, { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = function()
			render(state)
		end,
	})
end

---@param buf integer
function M.close(buf)
	vim.api.nvim_del_augroup_by_name("AtlasRepositoryReleases" .. buf)
end

return M
