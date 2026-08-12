local pipelines = require("atlas.pulls.providers.github.api.pipelines")

---@param item PullsPipeline|PullsPipelineJob
---@return string
local function state(item)
	return tostring(item.state or "UNKNOWN"):upper()
end

---@param ctx PullsPipelineActionContext
---@return boolean
local function has_pipeline_id(ctx)
	return tonumber(ctx.pipeline.provider_id) ~= nil or pipelines.parse_run_id(ctx.pipeline.url) ~= nil
end

---@param pipeline PullsPipeline
---@return boolean
local function is_running(pipeline)
	for _, job in ipairs(pipeline.jobs or {}) do
		if state(job) == "INPROGRESS" then
			return true
		end
	end
	return state(pipeline) == "INPROGRESS"
end

---@type PullsPipelineAction[]
return {
	{
		id = "rerun_failed_jobs",
		label = "Re-run failed jobs",
		is_available = function(ctx)
			return has_pipeline_id(ctx) and state(ctx.pipeline) == "FAILED" and not is_running(ctx.pipeline)
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
			return has_pipeline_id(ctx) and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun(ctx.pr, ctx.pipeline, false, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return has_pipeline_id(ctx) and is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.cancel(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "rerun_job",
		label = "Re-run job",
		is_available = function(ctx)
			return ctx.job ~= nil
				and tostring(ctx.job.id or "") ~= ""
				and state(ctx.job) ~= "INPROGRESS"
				and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun_job(ctx.pr, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
