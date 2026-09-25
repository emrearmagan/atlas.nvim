local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local repository = require("atlas.ui.repository")
local pages = require("atlas.ui.repository.pages")

local M = {}

---@param provider PullsProvider|IssuesProvider
---@return string[]
local function page_names(provider)
	return vim.tbl_map(function(page)
		return page.key
	end, pages.get(provider))
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
			target = git.local_repository()
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

---@param value string
---@param page string|nil
function M.open(value, page)
	value = vim.trim(value)
	local target, err
	if value == "." then
		target = git.local_repository()
		err = "No supported Git repository found"
	else
		target, err = providers.resolve(value)
	end
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

return M
