local icons = require("atlas.ui.shared.icons")
local pipelines = require("atlas.pulls.providers.azure.api.pipelines")

---@type PullsPipelineAction[]
return {
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		icon = icons.action("close"),
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return ctx.pipeline.state == "INPROGRESS" and ctx.pipeline.provider_state ~= "cancelling"
		end,
		run = function(ctx, done)
			pipelines.cancel(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "rerun_stage",
		label = "Re-run stage",
		icon = icons.action("retry"),
		confirm = "Re-run this stage and all its jobs?",
		is_available = function(ctx)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage|nil
			return stage ~= nil
				and stage.ref_name ~= nil
				and vim.tbl_contains({ "SUCCESSFUL", "FAILED", "STOPPED" }, ctx.pipeline.state)
		end,
		run = function(ctx, done)
			pipelines.update_stage(ctx.pr, ctx.pipeline, ctx.stage, "retry", function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "cancel_stage",
		label = "Cancel stage",
		icon = icons.action("close"),
		confirm = "Cancel this stage?",
		is_available = function(ctx)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage|nil
			return stage ~= nil and stage.ref_name ~= nil and stage.state == "INPROGRESS"
		end,
		run = function(ctx, done)
			pipelines.update_stage(ctx.pr, ctx.pipeline, ctx.stage, "cancel", function(_, err)
				done(err)
			end)
		end,
	},
}
