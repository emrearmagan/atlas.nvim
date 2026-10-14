local api = require("atlas.pulls.providers.azure.api.pipelines")
local actions = require("atlas.pulls.pipelines.azure.actions")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	-- fetch_history = nil,
	-- fetch_config = nil,
	fetch_job = api.fetch_job,
	fetch_job_log = api.fetch_job_log,
	-- parse = nil,
	-- step_target = nil,
	fetch_commit_status = api.fetch_commit_status,
	actions = actions,
}
