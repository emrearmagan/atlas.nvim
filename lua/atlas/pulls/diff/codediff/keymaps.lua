local M = {}

local explorer_ui = require("atlas.pulls.diff.codediff.explorer")
local resolver = require("atlas.core.keymaps")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")

---@param session AtlasDiffSession
function M.register(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local codediff = state.lifecycle.get_session(state.tabpage)
	local explorer = explorer_ui.get(state.lifecycle, state.tabpage)
	local buffers = vim.tbl_values({
		codediff and codediff.original_bufnr,
		codediff and codediff.modified_bufnr,
		explorer and explorer.bufnr,
	})
	review_keymaps.register(session, {
		buffers = buffers,
		reopen = session.reopen,
		help_key = resolver.resolve("pulls.external_help"),
		file_buffers = explorer and explorer.bufnr and { explorer.bufnr } or {},
		add_file_comment = function(pending)
			explorer_ui.add_file_comment(session, pending)
		end,
		toggle_file_reviewed = explorer_ui.toggle_file_reviewed,
	})
	if session.review_panel then
		buffers[#buffers + 1] = session.review_panel.buf
		review_panel.register_toggle(session.review_panel, buffers)
	end
end

return M
