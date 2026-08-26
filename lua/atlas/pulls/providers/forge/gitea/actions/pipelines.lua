local pipelines = require("atlas.pulls.providers.forge.gitea.api.pipelines")

---@param item PullsPipeline|PullsPipelineStage|PullsPipelineJob
---@return string
local function state(item)
	return item.state:upper()
end

---@param pipeline PullsPipeline
---@return boolean
local function is_running(pipeline)
	for _, stage in ipairs(pipeline.stages) do
		if state(stage) == "INPROGRESS" then
			return true
		end
		for _, job in ipairs(stage.jobs) do
			if state(job) == "INPROGRESS" then
				return true
			end
		end
	end
	return state(pipeline) == "INPROGRESS"
end

---@param item PullsPipeline|PullsPipelineJob
---@return boolean
local function failed_or_cancelled(item)
	local provider_state = tostring(item.provider_state or ""):lower()
	return state(item) == "FAILED"
		or provider_state == "failure"
		or provider_state == "failed"
		or provider_state == "cancelled"
		or provider_state == "canceled"
end

---@param pipeline PullsPipeline
---@return boolean
local function has_rerunnable_jobs(pipeline)
	if failed_or_cancelled(pipeline) then
		return true
	end
	for _, stage in ipairs(pipeline.stages) do
		for _, job in ipairs(stage.jobs) do
			if failed_or_cancelled(job) then
				return true
			end
		end
	end
	return false
end

---@type PullsPipelineAction[]
return {
	{
		id = "rerun_failed_jobs",
		label = "Re-run failed jobs",
		is_available = function(ctx)
			return pipelines.parse_run_id(ctx.pr, ctx.pipeline) ~= nil
				and has_rerunnable_jobs(ctx.pipeline)
				and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun(ctx.pr, ctx.pipeline, true, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "rerun_pipeline",
		label = "Re-run pipeline",
		is_available = function(ctx)
			return pipelines.parse_run_id(ctx.pr, ctx.pipeline) ~= nil and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun(ctx.pr, ctx.pipeline, false, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "rerun_job",
		label = "Re-run job",
		is_available = function(ctx)
			return pipelines.parse_run_id(ctx.pr, ctx.pipeline) ~= nil
				and ctx.job ~= nil
				and tonumber(ctx.job.id) ~= nil
				and state(ctx.job) ~= "INPROGRESS"
				and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun_job(ctx.pr, ctx.pipeline, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
