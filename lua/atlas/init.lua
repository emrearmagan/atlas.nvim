local M = {}

local logger = require("atlas.core.logger")

---@param opts AtlasConfig|nil
function M.setup(opts)
	require("atlas.config").setup(opts)
	require("atlas.core.logger").clear()
end

local function bootstrap_common()
	require("atlas.ui.shared.highlights").setup()
	require("atlas.ui.components.footer").setup()

	require("atlas.ui.popups.help").register_command("Commands", {
		{ name = "AtlasPulls", desc = "Open pulls domain" },
		{ name = "AtlasIssues", desc = "Open issues domain" },
		{ name = "AtlasClearCache", desc = "Clear Atlas cache" },
		{ name = "AtlasLogs", desc = "Open Atlas logs" },
	}, { index = 999, buffer = require("atlas.ui.layout").buf_id("main") })
end

---@param provider_id AtlasPullsProviderId|nil
---@return PullsProvider|nil
local function resolve_pulls_provider(provider_id)
	local config = require("atlas.config")
	local id = provider_id
	if id == nil then
		local providers = config.options.pulls and config.options.pulls.providers or {}
		if providers.bitbucket then
			id = "bitbucket"
		elseif providers.github then
			id = "github"
		elseif providers.gitlab then
			id = "gitlab"
		else
			id = "mock"
		end
	end

	if id == "mock" then
		return require("atlas.pulls.providers.mock")
	elseif id == "bitbucket" then
		return require("atlas.pulls.providers.bitbucket")
	elseif id == "github" then
		return require("atlas.pulls.providers.github")
	elseif id == "gitlab" then
		return require("atlas.pulls.providers.gitlab")
	end

	vim.notify(string.format("[Atlas] Unknown pulls provider: %s", id), vim.log.levels.ERROR)
	return nil
end

---@param provider_id AtlasIssuesProviderId|nil
---@return IssuesProvider|nil
local function resolve_issues_provider(provider_id)
	local config = require("atlas.config")
	local id = provider_id
	if id == nil then
		local providers = config.options.issues and config.options.issues.providers or {}
		if providers.jira then
			id = "jira"
		elseif providers.github then
			id = "github"
		elseif providers.gitlab then
			id = "gitlab"
		else
			id = "mock"
		end
	end

	if id == "mock" then
		return require("atlas.issues.providers.mock")
	elseif id == "jira" then
		return require("atlas.issues.providers.jira")
	elseif id == "github" then
		return require("atlas.issues.providers.github")
	elseif id == "gitlab" then
		return require("atlas.issues.providers.gitlab")
	end

	vim.notify(string.format("[Atlas] Unknown issues provider: %s", id), vim.log.levels.ERROR)
	return nil
end

---@param domain "pulls"|"issues"
---@param provider_id AtlasPullsProviderId|AtlasIssuesProviderId|nil
function M.open(domain, provider_id)
	logger.loginfo("Atlas open requested", { domain = domain, provider_id = provider_id })

	local layout = require("atlas.ui.layout")

	layout.ensure_open()
	bootstrap_common()
	layout.open()

	if domain == "pulls" then
		local provider = resolve_pulls_provider(provider_id)
		if provider == nil then
			return
		end

		layout.set_render_callback(function()
			require("atlas.pulls").render()
			local panel = require("atlas.pulls.ui.panel")
			if panel.is_open() then
				panel.render()
			end
		end)

		require("atlas.pulls").init(provider)
	elseif domain == "issues" then
		local provider = resolve_issues_provider(provider_id)
		if provider == nil then
			return
		end

		layout.set_render_callback(function()
			require("atlas.issues").render()
		end)

		require("atlas.issues").init(provider)
	end
end

return M
