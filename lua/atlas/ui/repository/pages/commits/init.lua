local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {
	key = "commits",
	label = "Commits",
	icon = icons.pulls("commit"),
}

---@param state { buf: integer, win: integer }
local function render(state)
	utils.buffer.center_message(state.buf, state.win, "Commits coming soon")
end

---@param opts { buf: integer, win: integer }
function M.open(opts)
	local state = { buf = opts.buf, win = opts.win }
	render(state)
	local group = vim.api.nvim_create_augroup("AtlasRepositoryCommits" .. opts.buf, { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = function()
			render(state)
		end,
	})
end

---@param buf integer
function M.close(buf)
	vim.api.nvim_del_augroup_by_name("AtlasRepositoryCommits" .. buf)
end

return M
