local api = require("atlas.pulls.providers.github.api.pipelines")
local actions = require("atlas.pulls.pipelines.github.actions")
local parser = require("atlas.pulls.pipelines.github.parser")

---@class GitHubPipeline : PullsPipeline
---@field workflow_file { path: string, repositoryFileUrl: string }|nil
---@field node_id string|nil
---@field workflow_id string|nil
---@field event string|nil
---@field source_repository string|nil

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_history = api.fetch_history,
	fetch_config = api.fetch_config,
	fetch_job = api.fetch_job,
	fetch_job_log = api.fetch_job_log,
	parse = parser.parse,
	step_target = parser.step_target,
	fetch_commit_status = api.fetch_commit_status,
	actions = actions,
}
