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
---@param entity PullRequest|Issue|nil
---@param back fun()|nil
local function open_target(target, entity, back)
	local provider = providers.load(target.provider, target.domain)

	if target.entity == "pr" then
		---@cast provider PullsProvider
		---@cast entity PullRequest|nil
		local pr = entity or { id = assert(target.id), repo_full_name = assert(target.repo_full_name) }

		require("atlas.pulls.ui.detail").open(pr, { provider = provider, back = back })
	elseif target.entity == "issue" then
		---@cast provider IssuesProvider
		---@cast entity Issue|nil
		local issue = entity or assert(provider.issue_ref(target))

		require("atlas.issues.ui.detail").open(issue, { provider = provider, back = back })
	elseif target.entity == "pipeline" then
		require("atlas.commands.pipelines").open(target.url)
	elseif target.entity == "repo" then
		require("atlas.commands.browse").open(target.url, target.page)
	end
end

-- A number can be a pull request or an issue, so it is tried as a pull request first.
---@param value string
local function open_reference(value)
	requests.run(function(done)
		return git.local_repository(nil, done)
	end, function(repository)
		if not repository then
			notify.error("A numeric reference requires a supported local Git repository", { vim_notify = true })
			return
		end

		if not config.provider_options(repository.provider) then
			notify.error(providers[repository.provider].name .. " is not configured", { vim_notify = true })
			return
		end

		local domains = { "pulls", "issues" }
		local function try(err)
			local domain = table.remove(domains, 1)
			if not domain then
				notify.error(err or "Reference not found", { vim_notify = true })
				return
			end

			local target, resolve_err = providers.resolve(value, { repository = repository, domain = domain })
			if not target then
				try(err or resolve_err)
				return
			end

			local provider = assert(providers.load(target.provider, domain))
			local ref = domain == "pulls" and { id = target.id, repo_full_name = target.repo_full_name }
				or provider.issue_ref(target)
			if not ref then
				try(err or "Could not determine issue key")
				return
			end

			requests.run(function(done)
				return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
			end, function(items, fetch_err)
				if items and items[1] then
					open_target(target, items[1])
				else
					try(fetch_err)
				end
			end)
		end

		try()
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
		if not repository then
			notify.error("No supported Git repository found", { vim_notify = true })
			return
		end

		if not branch then
			notify.error(errors.branch or "No current branch", { vim_notify = true })
			return
		end

		local provider = config.provider_options(repository.provider) and providers.load(repository.provider, "pulls")
		if not provider then
			notify.error("Pull requests are not available for " .. providers[repository.provider].name, {
				vim_notify = true,
			})
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

			if #pulls == 0 then
				notify.error("No open pull request for branch " .. branch, { vim_notify = true })
			elseif #pulls == 1 then
				require("atlas.pulls.ui.detail").open(pulls[1], { provider = provider })
			else
				picker.select({
					title = "Open pull request",
					items = pulls,
					format_item = function(pr)
						local title = pr.title .. " - "
						local id = "#" .. tostring(pr.id)
						return title .. id, { { title }, { id, "AtlasTextMuted" } }
					end,
					on_select = function(pr)
						if pr then
							require("atlas.pulls.ui.detail").open(pr, { provider = provider })
						end
					end,
				})
			end
		end)
	end)
end

---Opens the value in Atlas, or asks for one when it is nil.
---@param value string|nil A URL, Jira key, pull request or issue number, or "." for the current branch's pull request.
---@param opts? { back: fun()|nil }
function M.open(value, opts)
	requests.cancel()
	requests = request_scope.new()

	if not value then
		vim.ui.input({ prompt = "URL, issue key, or number: " }, function(input)
			if input and vim.trim(input) ~= "" then
				M.open(input)
			end
		end)
		return
	end

	value = vim.trim(value)
	if value == "." then
		open_current_branch()
	elseif providers.is_reference(value) then
		open_reference(value)
	else
		local target, err = providers.resolve(value)
		if not target then
			notify.error(err or "Unsupported Atlas URL", { vim_notify = true })
		elseif not config.provider_options(target.provider) then
			notify.error(providers[target.provider].name .. " is not configured", { vim_notify = true })
		else
			open_target(target, nil, opts and opts.back)
		end
	end
end

return M
