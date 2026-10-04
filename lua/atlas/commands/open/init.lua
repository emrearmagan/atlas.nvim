local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local requests = request_scope.new()

vim.api.nvim_create_autocmd("User", {
	group = vim.api.nvim_create_augroup("AtlasCommandOpen", { clear = true }),
	pattern = "AtlasUIClosed",
	callback = function()
		requests.cancel()
	end,
})

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
		require("atlas").open(target.domain, target.provider, { initial_view = provider.view_for_target(target) })
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
		local detail = require("atlas.issues.ui.detail")
		if entity then
			detail.open(entity, { provider = provider })
		else
			detail.open_ref(assert(provider.issue_ref(target)), { provider = provider })
		end
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
			return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
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
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
	end, function(issues, err)
		on_done(issues and issues[1] or nil, provider, err)
	end)
end

---@param value string
---@param repository AtlasTarget
---@param on_done fun(target: AtlasTarget|nil, provider: IssuesProvider|PullsProvider|nil, entity: Issue|PullRequest|nil, err: string|nil)
local function fetch_reference(value, repository, on_done)
	local candidates = {}
	local resolve_err
	for _, domain in ipairs({ "pulls", "issues" }) do
		if providers.domain(repository.provider, domain) and config.provider_options(repository.provider) then
			local target, err = providers.resolve(value, {
				repository = repository,
				domain = domain,
			})
			if target then
				table.insert(candidates, target)
			else
				resolve_err = resolve_err or err
			end
		end
	end

	local function try(index, last_err)
		local target = candidates[index]
		if target == nil then
			on_done(nil, nil, nil, last_err or (#candidates == 0 and resolve_err) or "Reference not found")
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

	if value == "." or value:match("^[#!]?%d+$") then
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, function(repository)
			if not repository then
				notify.error(
					value == "." and "No supported Git repository found"
						or "A numeric reference requires a supported local Git repository",
					{ vim_notify = true }
				)
				return
			end
			if value == "." then
				open_target(repository)
				return
			end
			fetch_reference(value, repository, function(target, provider, entity, resolve_err)
				if target then
					open_target(target, provider, entity)
				elseif resolve_err then
					notify.error(resolve_err, { vim_notify = true })
				end
			end)
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
