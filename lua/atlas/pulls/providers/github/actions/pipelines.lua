local icons = require("atlas.ui.shared.icons")
local pipelines = require("atlas.pulls.providers.github.api.pipelines")

---@param pipeline PullsPipeline
---@return boolean
local function is_running(pipeline)
	for _, stage in ipairs(pipeline.stages) do
		if stage.state == "INPROGRESS" then
			return true
		end
		for _, job in ipairs(stage.jobs) do
			if job.state == "INPROGRESS" then
				return true
			end
		end
	end
	return pipeline.state == "INPROGRESS"
end

---@type PullsPipelineAction[]
return {
	{
		id = "rerun_failed_jobs",
		label = "Re-run failed jobs",
		icon = icons.action("retry"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state == "FAILED" and not is_running(ctx.pipeline)
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
		icon = icons.action("retry"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and not is_running(ctx.pipeline)
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
		icon = icons.action("close"),
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and is_running(ctx.pipeline)
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
		icon = icons.action("retry"),
		is_available = function(ctx)
			return ctx.job ~= nil
				and tonumber(ctx.job.id) ~= nil
				and ctx.job.state ~= "INPROGRESS"
				and not is_running(ctx.pipeline)
		end,
		run = function(ctx, done)
			pipelines.rerun_job(ctx.pr, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
