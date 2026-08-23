local M = {
	current_pr = nil,
	current_details = nil,
	current_tab = nil,
	line_map = {},
	diffstat = nil,
	pipelines = nil,
	header_loading = false,
	win = nil,
	buf = nil,
	provider = nil,
	current_user = nil,
	on_update = nil,
}

function M.reset()
	M.current_pr = nil
	M.current_details = nil
	M.current_tab = "overview"
	M.line_map = {}
	M.diffstat = nil
	M.pipelines = nil
	M.header_loading = false
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.current_user = nil
	M.on_update = nil
end

return M
