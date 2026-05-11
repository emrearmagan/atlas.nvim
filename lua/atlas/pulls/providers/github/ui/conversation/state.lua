local M = {
	comments = nil, ---@type PullsComment[]|"loading"|string|nil
	activity = nil, ---@type PullsActivityEntry[]|"loading"|string|nil
	description = nil, ---@type string|"loading"|nil
}

function M.reset()
	M.comments = nil
	M.activity = nil
	M.description = nil
end

function M.any_loading()
	return M.comments == "loading" or M.activity == "loading" or M.description == "loading"
end

return M
