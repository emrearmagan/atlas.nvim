local request_scope = require("atlas.core.requests")

---@class PullsOverviewState
---@field reviewers PullsReviewer[]|"loading"|string|nil
---@field merge_checks PullsMergeCheck[]|"loading"|string|nil
---@field description_expanded boolean
---@field collapsed_pipelines table<PullsPipeline, boolean>
---@field requests AtlasRequestScope
local M = {
	reviewers = nil,
	merge_checks = nil,
	description_expanded = false,
	collapsed_pipelines = {},
	requests = request_scope.new(),
}

function M.reset()
	M.reviewers = nil
	M.merge_checks = nil
	M.description_expanded = false
	M.collapsed_pipelines = {}
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@param pipeline PullsPipeline
---@return boolean
function M.is_pipeline_expanded(pipeline)
	return M.collapsed_pipelines[pipeline] ~= true
end

---@param pipeline PullsPipeline
---@return boolean
function M.toggle_pipeline(pipeline)
	if #pipeline.stages == 0 then
		return false
	end
	M.collapsed_pipelines[pipeline] = M.is_pipeline_expanded(pipeline) and true or nil
	return true
end

return M
