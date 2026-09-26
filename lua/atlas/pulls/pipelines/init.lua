---@alias PullsPipelineState "UNKNOWN"|"STOPPED"|"CANCELED"|"SKIPPED"|"PENDING"|"QUEUED"|"PAUSED"|"MANUAL"|"SUCCESSFUL"|"INPROGRESS"|"FAILED"

---@class PullsPipeline
---@field id string
---@field name string
---@field state PullsPipelineState
---@field url string|nil
---@field number integer|nil
---@field commit string|nil
---@field branch string|nil
---@field started_at string|nil
---@field title string|nil
---@field job_count integer|nil
---@field stages PullsPipelineStage[]

---@class PullsPipelineStage
---@field name string|nil Nil when the provider has no native stage hierarchy.
---@field state PullsPipelineState
---@field jobs PullsPipelineJob[]

---@class PullsPipelineJob
---@field id string
---@field name string
---@field state PullsPipelineState
---@field url string|nil
---@field started_at string|nil
---@field duration number|nil Seconds
---@field steps PullsPipelineStep[]|nil

---@class PullsPipelineStep
---@field name string
---@field state PullsPipelineState
---@field started_at string|nil
---@field duration number|nil Seconds

---@class PullsPipelineContext
---@field provider AtlasPullsProviderId
---@field repo_full_name string
---@field target PullRequest|string|PullsPipeline

---@class AtlasPullsCIConfig
---@field backend PullsPipelineBackend|nil
---@field highlights AtlasLogRule[]|nil

---@alias PullsPipelineFetch fun(context: PullsPipelineContext, opts: { force_refresh?: boolean, pipeline?: PullsPipeline }|nil, on_done: fun(pipelines: PullsPipeline[]|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchHistory fun(context: PullsPipelineContext, on_done: fun(pipelines: PullsPipeline[]|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchJob fun(context: PullsPipelineContext, pipeline: PullsPipeline, job: PullsPipelineJob, on_done: fun(job: PullsPipelineJob|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchJobLog fun(context: PullsPipelineContext, pipeline: PullsPipeline, job: PullsPipelineJob, on_done: fun(log: PullsLog|nil, err: string|nil, status?: integer)): { cancel: fun() }|nil
---@alias PullsPipelineFetchConfig fun(context: PullsPipelineContext, pipeline: PullsPipeline, on_done: fun(file: { path: string, content: string }|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineParse fun(log: PullsLog): table<integer, PullsLogLine|PullsLogGroup>
---@alias PullsPipelineFetchCommitStatus fun(commit: PullsCommit, opts: { force_refresh: boolean|nil }|nil, on_done: fun(status: string|nil, url: string|nil, err: string|nil)): { cancel: fun() }|nil

---@class PullsPipelineBackend
---@field fetch PullsPipelineFetch
---@field fetch_history PullsPipelineFetchHistory|nil
---@field fetch_job PullsPipelineFetchJob|nil
---@field fetch_job_log PullsPipelineFetchJobLog|nil
---@field fetch_config PullsPipelineFetchConfig|nil
---@field parse PullsPipelineParse|nil
---@field step_target? fun(entries: (PullsLogLine|PullsLogGroup)[], step: PullsPipelineStep): PullsLogLine|PullsLogGroup|nil
---@field fetch_commit_status PullsPipelineFetchCommitStatus|nil
---@field actions PullsPipelineAction[]|nil

---@class PullsPipelineActionContext
---@field context PullsPipelineContext
---@field pipeline PullsPipeline
---@field stage PullsPipelineStage|nil
---@field job PullsPipelineJob|nil

---@class PullsPipelineAction
---@field id string
---@field label string
---@field icon string
---@field confirm string|nil
---@field is_available fun(ctx: PullsPipelineActionContext): boolean, string|nil
---@field run fun(ctx: PullsPipelineActionContext, done: fun(err: string|nil))

local M = {}

local config = require("atlas.config")
local ui = require("atlas.pulls.pipelines.ui")

---@param provider PullsProvider
---@return PullsPipelineBackend|nil
function M.get(provider)
	local options = config.provider_options(provider.id) or {}
	return (options.ci and options.ci.backend) or provider.capabilities.pipelines
end

---@param context PullRequest|PullsPipelineContext
---@param provider PullsProvider
---@param opts { selected_pipeline?: PullsPipeline, selected_stage?: PullsPipelineStage, selected_job?: PullsPipelineJob }|nil
function M.open(context, provider, opts)
	if context.source then
		---@cast context PullRequest
		context = { provider = context.provider, repo_full_name = context.repo_full_name, target = context }
	end
	---@cast context PullsPipelineContext
	ui.open(context, M.get(provider), opts)
end

return M
