local api = require("atlas.pulls.providers.github.api.pipelines")
local icons = require("atlas.ui.shared.icons")

local active_states = {
	PENDING = true,
	QUEUED = true,
	INPROGRESS = true,
}

---@param pipeline PullsPipeline
---@return boolean
local function is_active(pipeline)
	for _, stage in ipairs(pipeline.stages) do
		if active_states[stage.state] then
			return true
		end
		for _, job in ipairs(stage.jobs) do
			if active_states[job.state] then
				return true
			end
		end
	end
	return active_states[pipeline.state] == true
end

---@type PullsPipelineAction[]
return {
	{
		id = "rerun_failed_jobs",
		label = "Re-run failed jobs",
		icon = icons.action("retry"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and ctx.pipeline.state == "FAILED" and not is_active(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.rerun(ctx.context, ctx.pipeline, true, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "rerun_pipeline",
		label = "Re-run pipeline",
		icon = icons.action("retry"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and not is_active(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.rerun(ctx.context, ctx.pipeline, false, function(_, err)
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
			return tonumber(ctx.pipeline.id) ~= nil and is_active(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.cancel(ctx.context, ctx.pipeline, function(_, err)
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
				and active_states[ctx.job.state] ~= true
				and not is_active(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.rerun_job(ctx.context, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
