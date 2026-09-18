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

local STATE_PRIORITY = {
	UNKNOWN = 0,
	STOPPED = 1,
	SUCCESSFUL = 2,
	INPROGRESS = 3,
	FAILED = 4,
}

local STATE_LABEL = {
	UNKNOWN = "unknown",
	STOPPED = "stopped",
	SUCCESSFUL = "successful",
	INPROGRESS = "in progress",
	FAILED = "failed",
}

local MERGE_CHECK_STATE = {
	UNKNOWN = "muted",
	STOPPED = "muted",
	SUCCESSFUL = "successful",
	INPROGRESS = "inprogress",
	FAILED = "failed",
}

---@param items { state: PullsPipelineState }[]
---@return PullsPipelineState
---@return table<PullsPipelineState, integer>
local function summarize(items)
	---@type PullsPipelineState
	local aggregate = "UNKNOWN"
	local counts = {
		UNKNOWN = 0,
		STOPPED = 0,
		SUCCESSFUL = 0,
		INPROGRESS = 0,
		FAILED = 0,
	}

	for _, item in ipairs(items) do
		local normalized = tostring(item.state or "UNKNOWN"):upper()
		if STATE_PRIORITY[normalized] == nil then
			normalized = "UNKNOWN"
		end
		local state = normalized --[[@as PullsPipelineState]]
		counts[state] = counts[state] + 1
		if STATE_PRIORITY[state] > STATE_PRIORITY[aggregate] then
			aggregate = state
		end
	end

	return aggregate, counts
end

---@param items { state: PullsPipelineState }[]
---@return PullsPipelineState
function M.aggregate_state(items)
	local state = summarize(items)
	return state
end

---@param items { state: PullsPipelineState }[]
---@param label string
---@return PullsMergeCheck|nil
function M.to_merge_check(items, label)
	if type(items) ~= "table" or #items == 0 then
		return nil
	end

	local state, counts = summarize(items)
	return {
		key = "pipelines",
		state = MERGE_CHECK_STATE[state],
		label = label,
		details = { string.format("%d of %d %s", counts[state], #items, STATE_LABEL[state]) },
	}
end

---@param provider PullsProvider
---@return PullsPipelineBackend|nil
function M.get(provider)
	local options = config.provider_options(provider.id) or {}
	return (options.ci and options.ci.backend) or provider.capabilities.pipelines
end

return M
