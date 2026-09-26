local api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local icons = require("atlas.ui.shared.icons")

local active_states = {
	PENDING = true,
	QUEUED = true,
	PAUSED = true,
	MANUAL = true,
	INPROGRESS = true,
}

---@type PullsPipelineAction[]
return {
	{
		id = "run_pipeline",
		label = "Run new build",
		icon = icons.action("run"),
		confirm = "Start a new build from this branch's latest commit?",
		is_available = function(ctx)
			return tonumber(ctx.pipeline.id) ~= nil
		end,
		run = function(ctx, done)
			local target = ctx.context.target
			local branch = ctx.pipeline.branch
				or (type(target) == "string" and target)
				or (type(target) == "table" and target.source and target.source.branch)
			api.run_pipeline(ctx.context.repo_full_name, branch, function(_, err)
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
			return tonumber(ctx.pipeline.id) ~= nil and active_states[ctx.pipeline.state] == true
		end,
		run = function(ctx, done)
			api.stop_pipeline(ctx.context, ctx.pipeline, function(_, err)
				done(err)
			end)
		end,
	},
}
