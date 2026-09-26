local backend = require("atlas.pulls.pipelines.bitbucket")
local pipelines = require("atlas.pulls.pipelines.ui")
local icons = require("atlas.ui.shared.icons")

---@class BitbucketDeploymentActionContext
---@field repo AtlasRepository
---@field deployment BitbucketDeployment|nil

---@class BitbucketDeploymentAction
---@field id string
---@field label string
---@field icon string
---@field is_available fun(ctx: BitbucketDeploymentActionContext): boolean
---@field run fun(ctx: BitbucketDeploymentActionContext)

local M = {}

---@type BitbucketDeploymentAction
M.open_build = {
	id = "open_build",
	label = "Open build",
	icon = icons.action("pipeline"),
	is_available = function(ctx)
		return ctx.deployment ~= nil and ctx.deployment.pipeline_id ~= nil
	end,
	run = function(ctx)
		local deployment = ctx.deployment
		---@cast deployment BitbucketDeployment
		local id = deployment.pipeline_id
		---@cast id string
		pipelines.open({
			provider = "bitbucket",
			repo_full_name = ctx.repo.full_name,
			target = {
				id = id,
				name = "Pipeline " .. (deployment.pipeline_name or id),
				state = "UNKNOWN",
				url = deployment.pipeline_url,
				stages = {},
			},
		}, backend)
	end,
}

---@type BitbucketDeploymentAction
M.open_in_browser = {
	id = "open_in_browser",
	label = "Open deployment in browser",
	icon = icons.action("open_in_browser"),
	is_available = function(ctx)
		return ctx.deployment ~= nil and (ctx.deployment.url ~= nil or ctx.deployment.pipeline_url ~= nil)
	end,
	run = function(ctx)
		local deployment = ctx.deployment
		---@cast deployment BitbucketDeployment
		local url = deployment.url or deployment.pipeline_url
		---@cast url string
		vim.ui.open(url)
	end,
}

M.items = { M.open_build, M.open_in_browser }

return M
