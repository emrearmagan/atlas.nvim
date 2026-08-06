local M = {}

---@alias AtlasPullsProviderId "bitbucket"|"github"|"gitlab"
---@alias AtlasIssuesProviderId "jira"|"github"|"gitlab"
---@alias AtlasProviderId AtlasPullsProviderId|AtlasIssuesProviderId

---@class AtlasProviderDomain
---@field module string
---@field icon AtlasIconStyle|nil
---@field bookmark_key string|nil

---@class AtlasProvider
---@field id AtlasProviderId
---@field name string
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
	implementation.id = id
	implementation.name = provider.name
	if provider_domain.icon ~= nil then
		implementation.icon = provider_domain.icon.icon
		implementation.hl_group = provider_domain.icon.hl_group
	end
	return implementation
end

---@param id AtlasProviderId
---@param domain "pulls"|"issues"
---@return table|nil
function M.options(id, domain)
	local config = require("atlas.config").options or {}
	local domain_options = type(config[domain]) == "table" and config[domain] or nil
	local provider_options = domain_options and domain_options.providers or nil
	local result = type(provider_options) == "table" and provider_options[id] or nil
	return type(result) == "table" and result or nil
end

---@param domain "pulls"|"issues"
---@return AtlasProvider[]
function M.configured(domain)
	local result = {}
	for _, provider in ipairs(M.list(domain)) do
		if M.options(provider.id, domain) ~= nil then
			table.insert(result, provider)
		end
	end
	return result
end

add({
	id = "jira",
	name = "Jira",
	domains = {
		issues = {
			module = "atlas.issues.providers.jira",
			icon = { icon = "󰌃", hl_group = "AtlasJiraTheme" },
			bookmark_key = "J",
		},
	},
})

add({
	id = "github",
	name = "GitHub",
	default_host = "github.com",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.github",
			icon = { icon = "", hl_group = "AtlasGitHubTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.github",
			icon = { icon = "", hl_group = "AtlasGHIssuesTheme" },
			bookmark_key = "S",
		},
	},
})

add({
	id = "bitbucket",
	name = "Bitbucket",
	default_host = "bitbucket.org",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.bitbucket",
			icon = { icon = "", hl_group = "AtlasBitbucketTheme" },
		},
	},
})

add({
	id = "gitlab",
	name = "GitLab",
	default_host = "gitlab.com",
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitlab",
			icon = { icon = "", hl_group = "AtlasGitLabTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitlab",
			icon = { icon = "", hl_group = "AtlasGLIssuesTheme" },
			bookmark_key = "S",
		},
	},
})

return M
