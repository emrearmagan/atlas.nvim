local api = require("atlas.pulls.providers.gitlab.api.pipelines")
local icons = require("atlas.ui.shared.icons")

---@param item PullsPipeline|PullsPipelineJob
---@return boolean
local function can_retry(item)
	return item.state == "FAILED" or item.state == "CANCELED"
end

---@param item PullsPipeline|PullsPipelineJob
---@return boolean
local function can_cancel(item)
	---@cast item GitLabPipeline|GitLabPipelineJob
	local status = (item.status or ""):lower()
	return status == "created"
		or status == "waiting_for_resource"
		or status == "preparing"
		or status == "pending"
		or status == "running"
end

---@type PullsPipelineAction[]
return {
	{
		id = "retry_pipeline",
		label = "Retry pipeline",
		icon = icons.action("retry"),
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil and can_retry(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.retry(ctx.context, ctx.pipeline, function(_, err)
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
			return tonumber(ctx.pipeline.id) ~= nil and can_cancel(ctx.pipeline)
		end,
		run = function(ctx, done)
			api.cancel(ctx.context, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "retry_job",
		label = "Retry job",
		icon = icons.action("retry"),
		is_available = function(ctx)
			return ctx.job ~= nil and tonumber(ctx.job.id) ~= nil and can_retry(ctx.job)
		end,
		run = function(ctx, done)
			api.retry_job(ctx.context, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "cancel_job",
		label = "Cancel job",
		icon = icons.action("close"),
		confirm = "Cancel this job?",
		is_available = function(ctx)
			return ctx.job ~= nil and tonumber(ctx.job.id) ~= nil and can_cancel(ctx.job)
		end,
		run = function(ctx, done)
			api.cancel_job(ctx.context, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
