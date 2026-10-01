-- Uses CodeDiff internals for now, so upstream changes can break this.
-- A public plugin API is planned: https://github.com/esmuellert/codediff.nvim/issues/267
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")
local view = require("codediff.ui.view")
local keymaps = require("atlas.pulls.diffv2.codediff.keymaps")

---@param result AtlasDiffV2Result
local function open(result)
	local options = {
		panel = { name = "explorer" },
		git_root = result.root,
		original = path.empty(),
		modified = path.empty(),
		original_revision = result.base_revision,
		modified_revision = result.head_revision,
		layout = result.options.layout,
	}

	local previous_tab = vim.api.nvim_get_current_tabpage()
	local ok, state = pcall(function()
		local opened = view.create(options, "")
		---@cast opened table
		local tabpage = vim.api.nvim_win_get_tabpage(opened.modified_win)

		-- Empty panes need a valid diff result when returning to the tab.
		if not lifecycle.get_session(tabpage).stored_diff_result.changes then
			lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
		end

		return {
			tabpage = tabpage,
			left = { buf = opened.original_buf, win = opened.original_win },
			right = { buf = opened.modified_buf, win = opened.modified_win },
		}
	end)

	if ok then
		return state
	end

	-- CodeDiff could fail after opening its tab.
	-- so we use the new current tab to clean up what it left behind.. (hopefully)
	-- because otherwise the broken tab would stay open
	local tabpage = vim.api.nvim_get_current_tabpage()
	if tabpage ~= previous_tab then
		local session = lifecycle.get_session(tabpage)
		local buffers = session and { session.original_bufnr, session.modified_bufnr } or {}

		vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(tabpage) } })
		lifecycle.cleanup(tabpage)

		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
	end

	error(state, 0)
end

local function dispose(state)
	lifecycle.cleanup(state.tabpage)

	for _, pane in ipairs({ state.left, state.right }) do
		if vim.api.nvim_buf_is_valid(pane.buf) then
			vim.api.nvim_buf_delete(pane.buf, { force = true })
		end
	end
end

---@type AtlasDiffV2Renderer
local M = {
	open = open,
	setup_keymaps = keymaps.setup,
	dispose = dispose,
}

return M
