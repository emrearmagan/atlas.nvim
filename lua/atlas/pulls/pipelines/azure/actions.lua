local icons = require("atlas.ui.shared.icons")
local pipelines = require("atlas.pulls.providers.azure.api.pipelines")

---@type PullsPipelineAction[]
return {
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		icon = icons.get("close", "actions"),
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			local pipeline = ctx.pipeline
			---@cast pipeline AzurePipeline
			return pipeline.state == "INPROGRESS" and pipeline.provider_state ~= "cancelling"
		end,
		run = function(ctx, done)
			return pipelines.cancel(ctx.context, ctx.pipeline, function(_, err)
				done(err == nil, err)
			end)
		end,
	},
	{
		id = "rerun_stage",
		label = "Re-run stage",
		icon = icons.get("retry", "actions"),
		confirm = "Re-run this stage and all its jobs?",
		is_available = function(ctx)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage|nil
			return stage ~= nil
				and stage.ref_name ~= nil
				and vim.tbl_contains({ "SUCCESSFUL", "FAILED", "STOPPED" }, ctx.pipeline.state)
		end,
		run = function(ctx, done)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage
			return pipelines.update_stage(ctx.context, ctx.pipeline, stage, "retry", function(_, err)
				done(err == nil, err)
			end)
		end,
	},
	{
		id = "cancel_stage",
		label = "Cancel stage",
		icon = icons.get("close", "actions"),
		confirm = "Cancel this stage?",
		is_available = function(ctx)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage|nil
			return stage ~= nil and stage.ref_name ~= nil and stage.state == "INPROGRESS"
		end,
		run = function(ctx, done)
			local stage = ctx.stage
			---@cast stage AzurePipelineStage
			return pipelines.update_stage(ctx.context, ctx.pipeline, stage, "cancel", function(_, err)
				done(err == nil, err)
			end)
		end,
	},
}
