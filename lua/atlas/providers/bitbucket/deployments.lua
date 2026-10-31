local client = require("atlas.providers.bitbucket.client")
local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local url_encode = require("atlas.core.utils").url_encode

---@class BitbucketDeploymentEnvironment
---@field id string
---@field name string
---@field deployments BitbucketDeployment[]

---@class BitbucketDeployment
---@field number integer
---@field environment_id string
---@field state PullsPipelineState|"UNDEPLOYED"
---@field url string|nil
---@field pipeline_id string|nil
---@field pipeline_name string|nil
---@field pipeline_url string|nil
---@field branch string|nil
---@field commit string|nil
---@field started_at string|nil
---@field duration number|nil
---@field deployer string|nil

local M = {}

---@type table<string, PullsPipelineState|"UNDEPLOYED">
local states = {
	UNDEPLOYED = "UNDEPLOYED",
	PENDING = "PENDING",
	READY = "QUEUED",
	HALTED = "PAUSED",
	PAUSED = "MANUAL",
	IN_PROGRESS = "INPROGRESS",
	SUCCESSFUL = "SUCCESSFUL",
	FAILED = "FAILED",
	STOPPED = "STOPPED",
}

---@param repo AtlasRepository
---@param done fun(environments: BitbucketDeploymentEnvironment[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_environments(repo, done)
	local endpoint = string.format(
		"/repositories/%s/%s/environments?pagelen=100&fields=values.uuid,values.name,next",
		url_encode(repo.owner),
		url_encode(repo.repo_name)
	)
	return client.fetch_all_values(endpoint, function(result, err)
		if err then
			done(nil, err)
			return
		end
		---@cast result table
		---@type BitbucketDeploymentEnvironment[]
		local environments = {}
		for _, raw in ipairs(result.values) do
			environments[#environments + 1] = { id = raw.uuid, name = raw.name, deployments = {} }
		end
		done(environments, nil)
	end, { action = "Fetch deployment environments", repo = repo.full_name })
end

---@param repo AtlasRepository
---@param done fun(deployments: BitbucketDeployment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(repo, done)
	local fields = "values.number,values.environment.uuid"
		.. ",values.state.name,values.state.status.name,values.state.deployer.display_name"
		.. ",values.step.state.name,values.step.state.stage.name"
		.. ",values.state.url,values.state.started_on,values.state.completed_on,values.release.pipeline.build_number"
		.. ",values.release.name,values.release.url,values.release.commit.hash"
		.. ",values.release.pipeline.target.ref_name,values.release.pipeline.target.ref_type,values.release.pipeline.target.source"
	local endpoint = string.format(
		"/repositories/%s/%s/deployments?pagelen=100&sort=-state.started_on&fields=%s",
		url_encode(repo.owner),
		url_encode(repo.repo_name),
		fields
	)
	return client.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			done(nil, err)
			return
		end
		---@cast result table
		---@type BitbucketDeployment[]
		local deployments = {}
		for _, raw in ipairs(result.values) do
			local release = json.safe_table(raw.release)
			local pipeline = json.safe_table(release.pipeline)
			local target = json.safe_table(pipeline.target)
			local commit = json.safe_table(release.commit)
			local status = json.safe_table(raw.state.status)
			local state = states[status.name or raw.state.name] or "UNKNOWN"
			if state == "UNDEPLOYED" then
				local step = json.safe_table(json.safe_table(raw.step).state)
				local stage = json.safe_table(step.stage)
				state = states[stage.name] or states[step.name] or state
			end
			local started_at = json.safe_str(raw.state.started_on)
			deployments[#deployments + 1] = {
				number = raw.number,
				environment_id = raw.environment.uuid,
				state = state,
				url = json.safe_str(raw.state.url),
				pipeline_id = json.safe_str(pipeline.build_number),
				pipeline_name = json.safe_str(release.name),
				pipeline_url = json.safe_str(release.url),
				branch = json.safe_str(target.ref_type == "branch" and target.ref_name or target.source),
				commit = json.safe_str(commit.hash),
				started_at = started_at,
				duration = pipeline_utils.duration(started_at, json.safe_str(raw.state.completed_on)),
				deployer = json.safe_str(json.safe_table(raw.state.deployer).display_name),
			}
		end
		table.sort(deployments, function(a, b)
			return a.number > b.number
		end)
		done(deployments, nil)
	end, { action = "Fetch deployments", repo = repo.full_name })
end

return M
