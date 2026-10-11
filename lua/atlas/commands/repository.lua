local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local picker = require("atlas.ui.picker")
local repository = require("atlas.ui.repository")
local pages = require("atlas.ui.repository.pages")
local request_scope = require("atlas.core.requests")

local M = {}
local requests = request_scope.new()
local completion = {}

---@param provider PullsProvider|IssuesProvider
---@return string[]
local function page_names(provider)
	return vim.tbl_map(function(page)
		return page.key
	end, pages.get(provider))
end

local function search_repository()
	local actions = require("atlas.pulls.actions")
	local available = {}
	for _, configured in ipairs(providers.configured("pulls")) do
		local provider = providers.load(configured.id, "pulls")
		if
			provider
			and provider.capabilities.repository
			and actions.is_available("browse_repositories", { provider = provider })
		then
			table.insert(available, provider)
		end
	end

	local function browse(provider)
		if provider then
			actions.run("browse_repositories", { provider = provider })
		end
	end

	if #available == 0 then
		notify.error("No repository browsing providers configured", { vim_notify = true })
	elseif #available == 1 then
		browse(available[1])
	else
		picker.select({
			title = "Browse Repository - Provider",
			items = available,
			format_item = function(provider)
				return provider.name
			end,
			on_select = browse,
		})
	end
end

---@param arglead string
---@param args string[]|nil
---@return string[]
function M.complete(arglead, args)
	args = args or {}
	local options = {}
	if #args <= 1 then
		options = { "." }
	elseif #args == 2 then
		local target
		if args[1] == "." then
			local cwd = git.default_cwd()
			if completion.cwd ~= cwd then
				if completion.request then
					completion.request.cancel()
				end
				completion = { cwd = cwd }
			end
			local cache = completion
			if not cache.request then
				cache.request = git.local_repository(cwd, function(resolved)
					cache.repository = resolved
					cache.request = nil
				end)
			end
			target = cache.repository
		else
			target = providers.resolve(args[1])
		end
		if target and target.entity == "repo" and config.provider_options(target.provider) then
			local provider = providers.load(target.provider, target.domain)
			if provider and provider.capabilities.repository then
				options = page_names(provider)
			end
		end
	end
	return vim.tbl_filter(function(name)
		return name:find(arglead, 1, true) == 1
	end, options)
end

---@param target AtlasTarget|nil
---@param page string|nil
---@param err string|nil
local function open_repository(target, page, err)
	if not target or target.entity ~= "repo" or not target.repo_full_name then
		notify.error(err or "Expected a repository URL", { vim_notify = true })
		return
	end
	if not config.provider_options(target.provider) then
		notify.error("Provider not configured: " .. target.provider, { vim_notify = true })
		return
	end

	local provider = providers.load(target.provider, target.domain)
	if not provider or not provider.capabilities.repository then
		notify.error("Repository browsing is not available for this provider", { vim_notify = true })
		return
	end
	if page and not vim.tbl_contains(page_names(provider), page) then
		notify.error("Repository page is not available: " .. page, { vim_notify = true })
		return
	end
	repository.open(target.repo_full_name, provider, { page = page })
end

---@param value string|nil
---@param page string|nil
function M.open(value, page)
	requests.cancel()
	requests = request_scope.new()
	if not value then
		search_repository()
		return
	end

	value = vim.trim(value)
	if value == "." then
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, function(target)
			open_repository(target, page, "No supported Git repository found")
		end)
	else
		local target, err = providers.resolve(value)
		open_repository(target, page, err)
	end
end

return M
