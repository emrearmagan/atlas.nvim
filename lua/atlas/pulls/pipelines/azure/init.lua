local api = require("atlas.pulls.providers.azure.api.pipelines")
local actions = require("atlas.pulls.pipelines.azure.actions")
local parser = require("atlas.pulls.pipelines.azure.parser")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_pipeline = api.fetch_pipeline,
	fetch_history = api.fetch_history,
	fetch_config = api.fetch_config,
	fetch_job = api.fetch_job,
	fetch_job_log = api.fetch_job_log,
	parse = parser.parse,
	-- step_target = nil,
	fetch_commit_status = api.fetch_commit_status,
	actions = actions,
}
