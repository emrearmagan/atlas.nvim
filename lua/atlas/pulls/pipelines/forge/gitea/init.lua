local api = require("atlas.pulls.providers.forge.gitea.api.pipelines")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_commit_status = api.fetch_commit_status,
	fetch_job_log = api.fetch_job_log,
	actions = require("atlas.pulls.pipelines.forge.gitea.actions"),
}
