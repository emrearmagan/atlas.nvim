local api = require("atlas.pulls.providers.gitlab.api.pipelines")

---@type PullsPipelineBackend
return {
	fetch = api.fetch,
	fetch_details = api.fetch_details,
	fetch_job_log = api.fetch_job_log,
	actions = require("atlas.pulls.pipelines.gitlab.actions"),
}
