local M = {
	current_repo = nil,
	current_repo_details = nil,
	current_tab = "overview",
	line_map = {},
	win = nil,
	buf = nil,
	provider = nil,
}

function M.reset()
	M.current_repo = nil
	M.current_repo_details = nil
	M.current_tab = "overview"
	M.line_map = {}
	M.win = nil
	M.buf = nil
	M.provider = nil
end

return M
