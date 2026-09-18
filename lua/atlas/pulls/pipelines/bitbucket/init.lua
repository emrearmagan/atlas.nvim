local api = require("atlas.pulls.providers.bitbucket.api.pipelines")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_details = api.fetch_details,
	fetch_job_log = api.fetch_job_log,
	fetch_commit_status = api.fetch_commit_status,
	actions = require("atlas.pulls.pipelines.bitbucket.actions"),
}
