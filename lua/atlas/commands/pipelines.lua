local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local pipelines = require("atlas.pulls.pipelines")

local M = {}
local requests = request_scope.new()

---@param value string
function M.open(value)
	requests.cancel()
	requests = request_scope.new()
	value = vim.trim(value)

	local target, branch, err
	if value == "." then
		local root, root_err = git.repo_root()
		if not root then
			notify.error(root_err, { vim_notify = true })
			return
		end
		branch, err = git.current_branch(root)
		if not branch then
			notify.error(err, { vim_notify = true })
			return
		end
		target = git.local_repository(root)
	elseif value:match("^[#!]?%d+$") or value:find("://", 1, true) or value:match("^<") then
		local repository = value:match("^[#!]?%d+$") and git.local_repository() or nil
		target, err = providers.resolve(value, { repository = repository, domain = "pulls" })
		if not target or target.domain ~= "pulls" or (target.entity ~= "pr" and target.entity ~= "pipeline") then
			notify.error(err or "Expected a branch, pull request reference, or pipeline URL", { vim_notify = true })
			return
		end
	else
		branch = value
		target = git.local_repository()
	end
	if not target then
		notify.error("No supported Git repository found", { vim_notify = true })
		return
	end
	if not config.provider_options(target.provider) then
		notify.error("Pipeline provider is not configured: " .. target.provider, { vim_notify = true })
		return
	end

	local provider = providers.load(target.provider, "pulls")
	if not provider then
		notify.error("Unable to load pipeline provider: " .. target.provider, { vim_notify = true })
		return
	end
	---@cast provider PullsProvider
	if not pipelines.get(provider) then
		notify.error("Pipelines are not available for this provider", { vim_notify = true })
		return
	end

	if branch or target.entity == "pipeline" then
		local pipeline_target = branch
		if target.entity == "pipeline" then
			local id = tostring(assert(target.id))
			pipeline_target = {
				id = id,
				name = "Pipeline #" .. id,
				state = "UNKNOWN",
				url = target.url,
				stages = {},
			}
		end
		pipelines.open({
			provider = target.provider,
			repo_full_name = assert(target.repo_full_name),
			target = assert(pipeline_target),
		}, provider)
		return
	end

	---@type PullRequestRef
	local ref = { id = assert(target.id), repo_full_name = assert(target.repo_full_name) }
	notify.info("Fetching pull request...", { vim_notify = true })
	requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
	end, function(pulls, fetch_err)
		local pr = pulls and pulls[1]
		if fetch_err or not pr then
			notify.error(fetch_err or "Pull request not found", { vim_notify = true })
			return
		end
		pipelines.open(pr, provider)
	end)
end

return M
