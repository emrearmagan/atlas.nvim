local api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local icons = require("atlas.ui.shared.icons")

---@type PullsPipelineAction[]
return {
	{
		id = "run_pipeline",
		label = "Run pipeline",
		icon = icons.action("run"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state ~= "INPROGRESS"
		end,
		run = function(ctx, done)
			api.run_pipeline(ctx.pr, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "stop_pipeline",
		label = "Stop pipeline",
		icon = icons.action("stop"),
		confirm = "Stop this pipeline?",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state == "INPROGRESS"
		end,
		run = function(ctx, done)
			api.stop_pipeline(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
}
