---@class PullsOverviewState
---@field reviewers PullsReviewer[]|"loading"|string|nil
---@field description string|"loading"|nil
---@field merge_checks PullsMergeCheck[]|"loading"|string|nil
---@field description_expanded boolean
---@field collapsed_pipelines table<PullsPipeline, boolean>
local M = {
	reviewers = nil,
	description = nil,
	merge_checks = nil,
	description_expanded = false,
	collapsed_pipelines = {},
}

function M.reset()
	M.reviewers = nil
	M.description = nil
	M.merge_checks = nil
	M.description_expanded = false
	M.collapsed_pipelines = {}
end

---@param pipeline PullsPipeline
---@return boolean
function M.is_pipeline_expanded(pipeline)
	return M.collapsed_pipelines[pipeline] ~= true
end

---@param pipeline PullsPipeline
---@return boolean
function M.toggle_pipeline(pipeline)
	if type(pipeline.jobs) ~= "table" or #pipeline.jobs == 0 then
		return false
	end
	M.collapsed_pipelines[pipeline] = M.is_pipeline_expanded(pipeline) and true or nil
	return true
end

---@return boolean
function M.any_loading()
	return M.reviewers == "loading" or M.description == "loading" or M.merge_checks == "loading"
end

return M
