---@class AtlasPullsCIConfig
---@field backend PullsPipelineBackend|nil

---@alias PullsPipelineFetch fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(pipelines: PullsPipeline[]|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchDetails fun(pr: PullRequest, pipeline: PullsPipeline, opts: { force_refresh: boolean|nil }|nil, on_done: fun(pipeline: PullsPipeline|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchJobLog fun(pr: PullRequest, pipeline: PullsPipeline, job: PullsPipelineJob, on_done: fun(log: string|nil, err: string|nil)): { cancel: fun() }|nil
---@alias PullsPipelineFetchCommitStatus fun(commit: PullsCommit, opts: { force_refresh: boolean|nil }|nil, on_done: fun(status: string|nil, url: string|nil, err: string|nil)): { cancel: fun() }|nil

---@class PullsPipelineBackend
---@field fetch PullsPipelineFetch
---@field fetch_details PullsPipelineFetchDetails|nil
---@field fetch_job_log PullsPipelineFetchJobLog|nil
---@field fetch_commit_status PullsPipelineFetchCommitStatus|nil
---@field actions PullsPipelineAction[]|nil

---@class PullsPipelineActionContext
---@field pr PullRequest
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

---@param provider PullsProvider
---@return PullsPipelineBackend|nil
function M.get(provider)
	local options = config.provider_options(provider.id) or {}
	return (options.ci and options.ci.backend) or provider.capabilities.pipelines
end

return M
