local notify = require("atlas.core.notify")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")

local M = {}

---@param backend PullsPipelineBackend|nil
---@param ctx PullsPipelineActionContext
---@param on_select fun(action: PullsPipelineAction)
function M.open(backend, ctx, on_select)
	local available = {}
	for _, action in ipairs(backend and backend.actions or {}) do
		if action.is_available(ctx) then
			available[#available + 1] = action
		end
	end
	if #available == 0 then
		notify.warn("No pipeline actions available")
		return
	end

	picker.select({
		title = "Actions: " .. (ctx.job and ctx.job.name or ctx.stage and ctx.stage.name or ctx.pipeline.name),
		items = available,
		format_item = icons.format_action,
		on_select = function(action)
			if not action then
				return
			end
			if not action.confirm then
				on_select(action)
				return
			end
			vim.ui.input({ prompt = action.confirm .. " [y/N]: " }, function(input)
				local answer = vim.trim(input or ""):lower()
				if answer == "y" or answer == "yes" then
					on_select(action)
				end
			end)
		end,
	})
end

return M
