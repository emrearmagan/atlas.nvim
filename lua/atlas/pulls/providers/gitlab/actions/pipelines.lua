local checks = require("atlas.pulls.providers.gitlab.api.checks")

---@param item PullsPipeline|PullsPipelineJob
---@return string
local function state(item)
	return tostring(item.state or "UNKNOWN"):upper()
end

---@param item PullsPipeline|PullsPipelineJob
---@return boolean
local function can_retry(item)
	local value = tostring(item.provider_state or ""):lower()
	if value ~= "" then
		return value == "failed" or value == "canceled"
	end
	value = state(item)
	return value == "FAILED" or value == "STOPPED"
end

---@param item PullsPipeline|PullsPipelineJob
---@return boolean
local function can_cancel(item)
	local value = tostring(item.provider_state or ""):lower()
	if value ~= "" then
		return value == "created"
			or value == "waiting_for_resource"
			or value == "preparing"
			or value == "pending"
			or value == "running"
	end
	return state(item) == "INPROGRESS"
end

---@type PullsPipelineAction[]
return {
	{
		id = "retry_pipeline",
		label = "Retry pipeline",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.provider_id) ~= nil and can_retry(ctx.pipeline)
		end,
		run = function(ctx, done)
			checks.retry_pipeline(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "cancel_pipeline",
		label = "Cancel pipeline",
		confirm = "Cancel this pipeline?",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.provider_id) ~= nil and can_cancel(ctx.pipeline)
		end,
		run = function(ctx, done)
			checks.cancel_pipeline(ctx.pr, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "retry_job",
		label = "Retry job",
		is_available = function(ctx)
			return ctx.job ~= nil and tonumber(ctx.job.id) ~= nil and can_retry(ctx.job)
		end,
		run = function(ctx, done)
			checks.retry_pipeline_job(ctx.pr, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
	{
		id = "cancel_job",
		label = "Cancel job",
		confirm = "Cancel this job?",
		is_available = function(ctx)
			return ctx.job ~= nil and tonumber(ctx.job.id) ~= nil and can_cancel(ctx.job)
		end,
		run = function(ctx, done)
			checks.cancel_pipeline_job(ctx.pr, ctx.job, function(_, err)
				done(err)
			end)
		end,
	},
}
