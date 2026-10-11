local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local pipelines = require("atlas.pulls.pipelines")

local M = {}
local requests = request_scope.new()
local completion = {}

---@param arglead string
---@return string[]
function M.complete(arglead)
	local cwd = git.default_cwd()
	if completion.cwd ~= cwd then
		if completion.request then
			completion.request.cancel()
		end
		completion = { cwd = cwd }
	end
	local cache = completion
	if not cache.request then
		cache.request = git.list_remote_branches(cwd, "origin", function(branches)
			cache.branches = branches or {}
			cache.request = nil
		end)
	end
	if not cache.branches and arglead == "" then
		return {}
	end
	local options = { "." }
	vim.list_extend(options, cache.branches or {})
	return vim.tbl_filter(function(name)
		return name:find(arglead, 1, true) == 1
	end, options)
end

---@param target AtlasTarget|nil
---@param branch string|nil
local function open_target(target, branch)
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

---@param value string
function M.open(value)
	requests.cancel()
	requests = request_scope.new()
	value = vim.trim(value)

	local function open_reference(repository)
		local target, err = providers.resolve(value, { repository = repository, domain = "pulls" })
		if not target or target.domain ~= "pulls" or (target.entity ~= "pr" and target.entity ~= "pipeline") then
			notify.error(err or "Expected a branch, pull request reference, or pipeline URL", { vim_notify = true })
			return
		end
		open_target(target)
	end

	if value == "." then
		requests.run(function(done)
			return git.repo_root(nil, done)
		end, function(root, err)
			if not root then
				notify.error(err, { vim_notify = true })
				return
			end
			requests.all({
				branch = function(done)
					return git.current_branch(root, done)
				end,
				repository = function(done)
					return git.local_repository(root, done)
				end,
			}, function(values, errors)
				if not values.branch then
					notify.error(errors.branch, { vim_notify = true })
					return
				end
				open_target(values.repository, values.branch)
			end)
		end)
	elseif value:find("://", 1, true) or value:match("^<") then
		open_reference(nil)
	else
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, function(repository)
			if value:match("^[#!]?%d+$") then
				open_reference(repository)
			else
				open_target(repository, value)
			end
		end)
	end
end

return M
