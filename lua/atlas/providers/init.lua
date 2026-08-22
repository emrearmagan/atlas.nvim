local M = {}
local config = require("atlas.config")

---@alias AtlasPullsProviderId "bitbucket"|"github"|"gitlab"|"gitea"
---@alias AtlasIssuesProviderId "jira"|"github"|"gitlab"|"gitea"
---@alias AtlasProviderId AtlasPullsProviderId|AtlasIssuesProviderId

---@class AtlasProviderDomain
---@field module string
---@field bookmark_key string|nil
---@field bookmark_label string|nil

---@class AtlasProvider
---@field id AtlasProviderId
---@field name fun(domain: "pulls"|"issues"|nil): string
---@field icon fun(domain: "pulls"|"issues"): AtlasIconStyle
---@field default_host string|nil
---@field domains table<"pulls"|"issues", AtlasProviderDomain>

---@type AtlasProvider[]
local all = {}

---@param provider AtlasProvider
local function add(provider)
	M[provider.id] = provider
	table.insert(all, provider)
end

---@param domain "pulls"|"issues"|nil
---@return AtlasProvider[]
function M.list(domain)
	local result = {}
	for _, provider in ipairs(all) do
		if domain == nil or provider.domains[domain] ~= nil then
			table.insert(result, provider)
		end
	end
	return result
end

---@param domain "pulls"|"issues"|nil
---@return AtlasProviderId[]
function M.ids(domain)
	local result = {}
	for _, provider in ipairs(M.list(domain)) do
		table.insert(result, provider.id)
	end
	return result
end

---@param id AtlasProviderId
---@param domain "pulls"|"issues"
---@return AtlasProviderDomain|nil
function M.domain(id, domain)
	local provider = M[id]
	return provider and provider.domains[domain] or nil
end

---@param id AtlasProviderId
---@param domain "pulls"|"issues"
---@return PullsProvider|IssuesProvider|nil
function M.load(id, domain)
	local provider = M[id]
	local provider_domain = provider and provider.domains[domain] or nil
	if provider_domain == nil then
		return nil
	end
	local implementation = require(provider_domain.module)
	local icon = provider.icon(domain)
	implementation.id = id
	implementation.name = provider.name(domain)
	implementation.icon = icon.icon
	implementation.hl_group = icon.hl_group
	return implementation
end

---@param domain "pulls"|"issues"
---@return AtlasProvider[]
function M.configured(domain)
	local result = {}
	for _, provider in ipairs(M.list(domain)) do
		if config.domain_options(provider.id, domain) ~= nil then
			table.insert(result, provider)
		end
	end
	return result
end

add({
	id = "jira",
	name = function()
		return "Jira"
	end,
	icon = function()
		return { icon = "󰌃", hl_group = "AtlasJiraTheme" }
	end,
	domains = {
		issues = {
			module = "atlas.issues.providers.jira",
			bookmark_key = "J",
			bookmark_label = "JQL",
		},
	},
})

add({
	id = "github",
	name = function()
		return "GitHub"
	end,
	icon = function()
		return { icon = "", hl_group = "AtlasGitHubTheme" }
	end,
	default_host = "github.com",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.github",
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.github",
			bookmark_key = "S",
		},
	},
})

add({
	id = "bitbucket",
	name = function()
		return "Bitbucket"
	end,
	icon = function()
		return { icon = "", hl_group = "AtlasBitbucketTheme" }
	end,
	default_host = "bitbucket.org",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.bitbucket",
			bookmark_key = "S",
		},
	},
})

add({
	id = "gitlab",
	name = function()
		return "GitLab"
	end,
	icon = function()
		return { icon = "", hl_group = "AtlasGitLabTheme" }
	end,
	default_host = "gitlab.com",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitlab",
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitlab",
			bookmark_key = "S",
		},
	},
})

add({
	id = "gitea",
	name = function(domain)
		if domain == nil then
			return "Gitea / Forgejo"
		end
		local options = config.provider_options("gitea") or {}
		return options.api_type == "forgejo" and "Forgejo" or "Gitea"
	end,
	icon = function()
		local options = config.provider_options("gitea") or {}
		if options.api_type == "forgejo" then
			return { icon = "", hl_group = "AtlasForgejoTheme" }
		end
		return { icon = "", hl_group = "AtlasGiteaTheme" }
	end,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitea",
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitea",
			bookmark_key = "S",
		},
	},
})

return M
