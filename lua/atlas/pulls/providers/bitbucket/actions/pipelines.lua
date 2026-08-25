local pipelines = require("atlas.pulls.providers.bitbucket.api.pipelines")

---@type PullsPipelineAction[]
return {
	{
		id = "run_pipeline",
		label = "Run pipeline",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state ~= "INPROGRESS"
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
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state == "INPROGRESS"
		end,
		run = function(ctx, done)
			pipelines.stop_pipeline(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
}
