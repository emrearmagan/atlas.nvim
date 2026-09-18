local api = require("atlas.pulls.providers.gitlab.api.pipelines")
local actions = require("atlas.pulls.pipelines.gitlab.actions")
local parser = require("atlas.pulls.pipelines.gitlab.parser")

---@class GitLabPipeline : PullsPipeline
---@field status string
---@field project_path string
---@field sha string
---@field config_path string

---@class GitLabPipelineJob : PullsPipelineJob
---@field status string
---@field project_path string

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_history = api.fetch_history,
	fetch_config = api.fetch_config,
	fetch_job = api.fetch_job,
	fetch_job_log = api.fetch_job_log,
	parse = parser.parse,
	fetch_commit_status = api.fetch_commit_status,
	actions = actions,
}
