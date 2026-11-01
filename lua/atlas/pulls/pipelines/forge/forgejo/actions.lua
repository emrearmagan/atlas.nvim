local icons = require("atlas.ui.shared.icons")
local pipelines = require("atlas.pulls.providers.forge.forgejo.api.pipelines")

---@type PullsPipelineAction[]
return {
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		icon = icons.get("close", "actions"),
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return pipelines.parse_run_number(ctx.context, ctx.pipeline) ~= nil
				and ctx.pipeline.state:upper() == "INPROGRESS"
		end,
		run = function(ctx, done)
			return pipelines.cancel(ctx.context, ctx.pipeline, function(_, err)
				done(err == nil, err)
			end)
		end,
	},
}
