local M = {}

local icons = require("atlas.ui.shared.icons")

---@param web_base string
---@param request fun(method: string, url: string, label: string, on_done: fun(result: table|nil, err: string|nil)): { cancel: fun() }|nil
---@return PullsPipelineAction[]
function M.new(web_base, request)
	local queue_url = web_base .. "/rest/api/latest/queue/"

	local function send(method, key, label, done)
		local url = queue_url .. key .. "?os_authType=basic"
		return request(method, url, label, function(_, err)
			done(err)
		end)
	end

	return {
		{
			id = "run_pipeline",
			label = "Run pipeline",
			icon = icons.action("run"),
			is_available = function(ctx)
				return ctx.pipeline.state ~= "INPROGRESS"
			end,
			run = function(ctx, done)
				local key = ctx.pipeline.id:match("^(.*)%-%d+$")
				return send("POST", key, "run pipeline", done)
			end,
		},
		{
			id = "rerun_failed_jobs",
			label = "Re-run failed jobs",
			icon = icons.action("retry"),
			is_available = function(ctx)
				return ctx.pipeline.state == "FAILED"
			end,
			run = function(ctx, done)
				return send("PUT", ctx.pipeline.id, "retry pipeline", done)
			end,
		},
		{
			id = "stop_job",
			label = "Stop job",
			icon = icons.action("stop"),
			confirm = "Stop this job?",
			is_available = function(ctx)
				return ctx.job ~= nil and ctx.job.state == "INPROGRESS"
			end,
			run = function(ctx, done)
				return send("DELETE", ctx.job.id, "stop job", done)
			end,
		},
	}
end

return M
