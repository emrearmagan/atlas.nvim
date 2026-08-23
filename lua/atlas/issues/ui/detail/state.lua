local M = {
	current_issue = nil,
	current_details = nil,
	current_tab = nil,
	line_map = {},
	header_loading = false,
	win = nil,
	buf = nil,
	provider = nil,
	current_user = nil,
	on_update = nil,
}

function M.reset()
	M.current_issue = nil
	M.current_details = nil
	M.current_tab = nil
	M.line_map = {}
	M.header_loading = false
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.current_user = nil
	M.on_update = nil
end

return M
