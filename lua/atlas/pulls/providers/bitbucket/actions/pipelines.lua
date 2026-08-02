local pipelines = require("atlas.pulls.providers.bitbucket.api.pipelines")

---@param pipeline PullsPipeline
---@return boolean
local function has_pipeline_id(pipeline)
	return tostring(pipeline.provider_id or "") ~= ""
		or tostring(pipeline.url or ""):match("/pipelines/results/%d+") ~= nil
end

---@param pipeline PullsPipeline
---@return string
local function state(pipeline)
	return tostring(pipeline.state or "UNKNOWN"):upper()
end

---@type PullsPipelineAction[]
return {
	{
		id = "run_pipeline",
		label = "Run pipeline",
		is_available = function(ctx)
			return has_pipeline_id(ctx.pipeline) and state(ctx.pipeline) ~= "INPROGRESS"
		end,
		run = function(ctx, done)
			pipelines.run_pipeline(ctx.pr, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "stop_pipeline",
		label = "Stop pipeline",
		confirm = "Stop this pipeline?",
		is_available = function(ctx)
			return has_pipeline_id(ctx.pipeline) and state(ctx.pipeline) == "INPROGRESS"
		end,
		run = function(ctx, done)
			pipelines.stop_pipeline(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
}
