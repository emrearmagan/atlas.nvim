local backend = require("atlas.pulls.pipelines.bitbucket")
local api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local notify = require("atlas.core.notify")
local pipelines = require("atlas.pulls.pipelines.ui")
local icons = require("atlas.ui.shared.icons")

---@class BitbucketDeploymentActionContext
---@field repo AtlasRepository
---@field deployment BitbucketDeployment|nil

---@class BitbucketDeploymentAction
---@field id string
---@field label string|fun(ctx: BitbucketDeploymentActionContext): string
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

---@type BitbucketDeploymentAction
M.run_build = {
	id = "run_build",
	label = function(ctx)
		local deployment = ctx.deployment
		---@cast deployment BitbucketDeployment
		return string.format("Run new build on %s", deployment.branch)
	end,
	icon = icons.action("run"),
	is_available = function(ctx)
		return ctx.deployment ~= nil and ctx.deployment.branch ~= nil
	end,
	run = function(ctx)
		local deployment = ctx.deployment
		---@cast deployment BitbucketDeployment
		local branch = deployment.branch
		---@cast branch string
		vim.ui.input(
			{ prompt = "Start a new build from the latest commit on '" .. branch .. "'? [y/N]: " },
			function(input)
				local answer = vim.trim(input or ""):lower()
				if answer ~= "y" and answer ~= "yes" then
					return
				end
				api.run_pipeline(ctx.repo.full_name, branch, function(_, err)
					if err then
						notify.error(err)
					else
						notify.info("New build started on " .. branch)
					end
				end)
			end
		)
	end,
}

M.items = { M.open_build, M.run_build, M.open_in_browser }

return M
