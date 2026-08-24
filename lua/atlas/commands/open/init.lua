local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local requests = request_scope.new()

---@param target AtlasTarget
---@param provider IssuesProvider|PullsProvider|nil
---@param entity Issue|PullRequest|nil
local function open_target(target, provider, entity)
	provider = provider or providers.load(target.provider, target.domain)
	if provider == nil or config.provider_options(target.provider) == nil then
		notify.error(string.format("Provider not configured for %s: %s", target.domain, target.provider), {
			vim_notify = true,
		})
		return
	end

	if target.entity == "repo" then
		require("atlas").open(target.domain, target.provider, { initial_view = provider.search_view(target) })
	elseif target.entity == "pr" then
		---@cast entity PullRequest|nil
		---@cast provider PullsProvider|nil
		require("atlas.pulls.ui.detail").open(
			entity or { id = assert(target.id), repo_full_name = assert(target.repo_full_name) },
			{ provider = provider }
		)
	elseif target.entity == "issue" then
		---@cast entity Issue|nil
		---@cast provider IssuesProvider|nil
		require("atlas.issues.ui.detail").open(entity or assert(provider.issue_ref(target)), { provider = provider })
	else
		notify.error("Unsupported Atlas target: " .. tostring(target.entity), { vim_notify = true })
	end
end

---@param target AtlasTarget
---@param on_done fun(entity: Issue|PullRequest|nil, provider: IssuesProvider|PullsProvider, err: string|nil)
local function fetch_candidate(target, on_done)
	local provider = assert(providers.load(target.provider, target.domain))
	if target.domain == "pulls" then
		---@cast provider PullsProvider
		---@type PullRequestRef
		local ref = { id = assert(target.id), repo_full_name = assert(target.repo_full_name) }
		requests.run(function(done)
			return provider.capabilities.core.fetch_by_refs({ ref }, { force_load = true }, done)
		end, function(pulls, err)
			on_done(pulls and pulls[1] or nil, provider, err)
		end)
		return
	end

	---@cast provider IssuesProvider
	local ref = provider.issue_ref(target)
	if ref == nil then
		on_done(nil, provider, "Could not determine issue key")
		return
	end
	requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_load = true }, done)
	end, function(issues, err)
		on_done(issues and issues[1] or nil, provider, err)
	end)
end

---@param number integer
---@param repository AtlasTarget
---@param on_done fun(target: AtlasTarget|nil, provider: IssuesProvider|PullsProvider|nil, entity: Issue|PullRequest|nil, err: string|nil)
local function fetch_repository_number(number, repository, on_done)
	local candidates = {}
	for _, domain in ipairs({ "pulls", "issues" }) do
		if providers.domain(repository.provider, domain) and config.provider_options(repository.provider) then
			local entity = domain == "pulls" and "pr" or "issue"
			local target = vim.tbl_extend("force", {}, repository, {
				domain = domain,
				entity = entity,
				id = number,
				number = number,
			})
			table.insert(candidates, target)
		end
	end

	local function try(index, last_err)
		local target = candidates[index]
		if target == nil then
			on_done(nil, nil, nil, last_err or "Reference not found")
			return
		end
		fetch_candidate(target, function(entity, provider, err)
			if entity then
				on_done(target, provider, entity, nil)
			else
				try(index + 1, err)
			end
		end)
	end

	try(1)
end

---@param value string
function M.open(value)
	requests.cancel()
	requests = request_scope.new()
	value = vim.trim(value)

	if value == "." then
		local repository = git.local_repository()
		if repository == nil then
			notify.error("No supported Git repository found", { vim_notify = true })
			return
		end
		open_target(repository)
		return
	end

	local number = value:match("^#?(%d+)$")
	if number then
		local id = assert(tonumber(number))
		---@cast id integer
		local repository = git.local_repository()
		if repository == nil then
			notify.error("A numeric reference requires a supported local Git repository", { vim_notify = true })
			return
		end
		fetch_repository_number(id, repository, function(target, provider, entity, resolve_err)
			if target then
				open_target(target, provider, entity)
			elseif resolve_err then
				notify.error(resolve_err, { vim_notify = true })
			end
		end)
		return
	end

	local target, err = providers.resolve(value)
	if target == nil then
		notify.error(err or "Unsupported Atlas URL", { vim_notify = true })
		return
	end
	open_target(target)
end

return M
