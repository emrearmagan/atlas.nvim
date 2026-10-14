local api = require("atlas.pulls.providers.forge.forgejo.api.pipelines")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_commit_status = api.fetch_commit_status,
	fetch_job_log = api.fetch_job_log,
	actions = require("atlas.pulls.pipelines.forge.forgejo.actions"),
}
