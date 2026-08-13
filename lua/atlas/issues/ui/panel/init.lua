local M = {}

local issue_panel = require("atlas.issues.ui.panel.issue")

function M.is_open()
	return issue_panel.is_open()
end

function M.render()
	return issue_panel.render()
end

function M.on_select(issue, opts)
	local detail_buf = require("atlas.ui.layout").buf_id("detail")
	if detail_buf ~= nil and vim.api.nvim_buf_is_valid(detail_buf) then
		require("atlas.issues.ui.panel.keymaps").register(detail_buf)
	end
	return issue_panel.on_select(issue, opts)
end

function M.next_tab()
	return issue_panel.next_tab()
end

function M.prev_tab()
	return issue_panel.prev_tab()
end

function M.close()
	return issue_panel.close()
end

return M
