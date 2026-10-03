require("diffview")

local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local lib = require("diffview.lib")
local RevType = require("diffview.vcs.rev").RevType
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView
local keymaps = require("atlas.pulls.diffv2.diffview.keymaps")

---@param result AtlasDiffV2Result
---@param callbacks AtlasDiffV2Callbacks
local function open(result, callbacks)
	local view = CDiffView({
		git_root = result.root,
		left = GitRev(RevType.COMMIT, result.base_revision),
		right = GitRev(RevType.COMMIT, result.head_revision),
		update_files = function()
			return {}
		end,
	})

	view.emitter:on("post_layout", function()
		view.cur_layout:open_null()
		view.panel:close()
	end)

	lib.add_view(view)
	local ok, state = pcall(function()
		view:open()

		local layout = view.cur_layout
		local right = { buf = vim.api.nvim_win_get_buf(layout.b.id), win = layout.b.id }
		local left = { buf = right.buf }

		if layout.a then
			left = { buf = vim.api.nvim_win_get_buf(layout.a.id), win = layout.a.id }
		end

		return {
			tabpage = view.tabpage,
			result = result,
			callbacks = callbacks,
			left = left,
			right = right,
			diffview = view,
		}
	end)

	if ok then
		return state
	end

	if view.commit_log_panel then
		view:close()
	else
		-- DiffView:close() requires the panel created after its layout opens.
		StandardView.close(view)
	end

	lib.dispose_view(view)

	error(state, 0)
end

local function dispose(state)
	state.diffview:close()
	lib.dispose_view(state.diffview)
end

---@type AtlasDiffV2Renderer
local M = {
	open = open,
	setup_keymaps = keymaps.setup,
	dispose = dispose,
}

return M
