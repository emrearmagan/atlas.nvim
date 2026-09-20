local request_scope = require("atlas.core.requests")
local pipeline_api = require("atlas.pulls.pipelines")
local pipeline_utils = require("atlas.pulls.pipelines.utils")

---@class PullsDetailState
---@field current_pr PullRequest|nil
---@field current_details PullRequestDetails|nil
---@field current_tab string|nil
---@field tabs PullsDetailTab[]
---@field line_map table<integer, table>
---@field diffstat PullsDiffstatEntry[]|"loading"|string|nil
---@field merge_checks PullsMergeCheck[]|"loading"|string|nil
---@field pipelines PullsPipeline[]|"loading"|string|nil
---@field pr_loading boolean
---@field details_loading boolean
---@field links AtlasDetailLinks|nil
---@field win integer|nil
---@field buf integer|nil
---@field provider PullsProvider|nil
---@field on_update fun(pr: PullRequest, result: PullsActionResult|nil)|nil
---@field requests AtlasRequestScope
---@field spinner_timer uv.uv_timer_t|nil
local M = {
	current_pr = nil,
	current_details = nil,
	current_tab = nil,
	tabs = {},
	line_map = {},
	diffstat = nil,
	merge_checks = nil,
	pipelines = nil,
	pr_loading = false,
	details_loading = false,
	win = nil,
	buf = nil,
	provider = nil,
	on_update = nil,
	requests = request_scope.new(),
	spinner_timer = nil,
}

function M.reset()
	M.current_pr = nil
	M.current_details = nil
	M.current_tab = nil
	M.tabs = {}
	M.line_map = {}
	M.diffstat = nil
	M.merge_checks = nil
	M.pipelines = nil
	M.pr_loading = false
	M.details_loading = false
	M.links = nil
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.on_update = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.spinner_timer = nil
end

---@return PullsMergeCheck[]
---@return boolean loading
function M.get_merge_checks()
	local native = M.merge_checks
	local pipelines = M.pipelines
	local provider = M.provider
	local use_native = not provider or pipeline_api.get(provider) == provider.capabilities.pipelines
	local checks = {}
	local has_pipeline_check = false
	if type(native) == "table" then
		for _, check in ipairs(native) do
			if check.key ~= "pipelines" or use_native then
				checks[#checks + 1] = check
				has_pipeline_check = has_pipeline_check or check.key == "pipelines"
			end
		end
	elseif type(native) == "string" then
		checks[#checks + 1] = {
			key = "merge_checks",
			label = "Merge checks",
			state = native == "loading" and "inprogress" or "warning",
			details = { native == "loading" and "Loading..." or native },
		}
	end
	if has_pipeline_check then
		return checks, false
	end

	if type(pipelines) == "table" then
		local check = pipeline_utils.to_merge_check(pipelines, "Pipelines")
		if check then
			checks[#checks + 1] = check
		end
	elseif type(pipelines) == "string" then
		checks[#checks + 1] = {
			key = "pipelines",
			label = "Pipelines",
			state = pipelines == "loading" and "inprogress" or "warning",
			details = { pipelines == "loading" and "Loading..." or pipelines },
		}
	end
	return checks, native == "loading" or pipelines == "loading"
end

return M
