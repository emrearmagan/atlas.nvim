local pipelines = require("atlas.pulls.providers.gitea.forgejo.api.pipelines")

---@type PullsPipelineAction[]
return {
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return pipelines.parse_run_number(ctx.pr, ctx.pipeline) ~= nil
				and tostring(ctx.pipeline.state or ""):upper() == "INPROGRESS"
		end,
		run = function(ctx, done)
			pipelines.cancel(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
}
