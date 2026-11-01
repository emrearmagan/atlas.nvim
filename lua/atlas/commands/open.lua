local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
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

	if target.entity == "pr" then
		---@cast entity PullRequest|nil
		---@cast provider PullsProvider
		require("atlas.pulls.ui.detail").open(
			entity or { id = assert(target.id), repo_full_name = assert(target.repo_full_name) },
			{ provider = provider }
		)
	elseif target.entity == "issue" then
		---@cast entity Issue|nil
		---@cast provider IssuesProvider
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

local function prompt()
	vim.ui.input({ prompt = "URL, issue key, or number: " }, function(input)
		if input and vim.trim(input) ~= "" then
			M.open(vim.trim(input))
		end
	end)
end

local function open_current_branch()
	local cwd = git.default_cwd()
	requests.all({
		repository = function(done)
			return git.local_repository(cwd, done)
		end,
		branch = function(done)
			return git.current_branch(cwd, done)
		end,
	}, function(values, errors)
		local repository, branch = values.repository, values.branch
		local provider = repository
			and config.provider_options(repository.provider)
			and providers.load(repository.provider, "pulls")
		if not repository or not branch or not provider then
			local reason = not repository and "No supported Git repository found"
				or not branch and errors.branch
				or "Pull requests are not available for " .. providers[repository.provider].name
			notify.warn(reason, { vim_notify = true })
			prompt()
			return
		end
		---@cast provider PullsProvider

		requests.run(function(done)
			local view = provider.repository_view(repository, branch)
			return provider.capabilities.core.fetch_pullrequests(view, { force_refresh = true, pagelen = 50 }, done)
		end, function(page, fetch_errors)
			if fetch_errors and #fetch_errors > 0 then
				notify.error(table.concat(fetch_errors, "; "), { vim_notify = true })
				return
			end
			local pulls = vim.tbl_filter(function(pr)
				return pr.state == "open" or pr.state == "draft"
			end, page.items)
			local function open_pr(pr)
				if pr then
					require("atlas.pulls.ui.detail").open(pr, { provider = provider })
				end
			end

			if #pulls == 0 then
				notify.info("No open pull request for branch " .. branch, { vim_notify = true })
			elseif #pulls == 1 then
				open_pr(pulls[1])
			else
				picker.select({
					title = "Open pull request",
					items = pulls,
					format_item = function(pr)
						return string.format("#%s %s", tostring(pr.id), pr.title)
					end,
					on_select = open_pr,
				})
			end
		end)
	end)
end

---@param value string|nil A URL, Jira key, pull request or issue number, "." for the current branch's pull request, or nil to ask.
function M.open(value)
	requests.cancel()
	requests = request_scope.new()
	if not value then
		prompt()
		return
	end
	value = vim.trim(value)

	if value == "." then
		open_current_branch()
		return
	end

	if value:match("^[#!]?%d+$") then
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, function(repository)
			if not repository then
				notify.error("A numeric reference requires a supported local Git repository", { vim_notify = true })
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
