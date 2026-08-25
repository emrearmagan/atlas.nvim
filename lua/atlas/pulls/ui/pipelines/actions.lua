local M = {}

local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")

---@class PullsPipelineActionContext
---@field pr PullRequest
---@field pipeline PullsPipeline
---@field stage PullsPipelineStage|nil
---@field job PullsPipelineJob|nil

---@class PullsPipelineAction
---@field id string
---@field label string
---@field confirm string|nil
---@field is_available fun(ctx: PullsPipelineActionContext): boolean, string|nil
---@field run fun(ctx: PullsPipelineActionContext, done: fun(err: string|nil))

---@param provider PullsProvider|nil
---@param ctx PullsPipelineActionContext
---@param on_select fun(action: PullsPipelineAction)
function M.open(provider, ctx, on_select)
	local available = {}
	local pipelines = provider and provider.capabilities.pipelines
	local actions = (pipelines and pipelines.actions) or {}
	for _, action in ipairs(actions) do
		if action.is_available(ctx) then
			table.insert(available, action)
		end
	end
	if #available == 0 then
		notify.warn("No pipeline actions available")
		return
	end

	picker.select({
		title = "Choose pipeline action",
		items = available,
		kind = "atlas_pipeline_actions",
		format_item = function(action)
			return action.label
		end,
		on_select = function(action)
			if not action then
				return
			end
			if not action.confirm then
				on_select(action)
				return
			end
			vim.ui.input({ prompt = action.confirm .. " [y/N]: " }, function(input)
				local answer = vim.trim(tostring(input or "")):lower()
				if answer == "y" or answer == "yes" then
					on_select(action)
				end
			end)
		end,
	})
end

return M
