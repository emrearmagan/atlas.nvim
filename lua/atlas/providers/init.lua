local M = {}
local config = require("atlas.config")
local url = require("atlas.providers.url")

---@alias AtlasPullsProviderId "bitbucket"|"github"|"gitlab"|"gitea"|"forgejo"
---@alias AtlasIssuesProviderId "jira"|"github"|"gitlab"|"gitea"|"forgejo"
---@alias AtlasProviderId AtlasPullsProviderId|AtlasIssuesProviderId
---@alias AtlasDomain "pulls"|"issues"
---@alias AtlasEntity "pr"|"issue"|"repo"

---@class AtlasTarget
---@field provider AtlasProviderId
---@field domain AtlasDomain
---@field entity AtlasEntity
---@field url string
---@field host string
---@field owner string|nil
---@field repo string|nil
---@field project_path string|nil
---@field workspace string|nil
---@field number integer|nil
---@field id string|number|nil
---@field repo_full_name string|nil
---@field repository_url string|nil
---@field issue_key string|nil

---@class AtlasProviderDomain
---@field module string
---@field icon AtlasIconStyle|nil
---@field bookmark_key string|nil
---@field bookmark_label string|nil

---@class AtlasProvider
---@field id AtlasProviderId
---@field name string
---@field resolver { resolve: fun(value: string, parsed: AtlasParsedUrl|nil): AtlasTarget|nil, string|nil }
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
	if provider_domain.icon then
		implementation.icon = provider_domain.icon.icon
		implementation.hl_group = provider_domain.icon.hl_group
	end
	return implementation
end

---@param value string
---@return AtlasTarget|nil, string|nil
function M.resolve(value)
	local cleaned = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	cleaned = cleaned:match("^<(.*)>$") or cleaned

	local parsed, parse_err = url.parse(cleaned)
	local resolve_err
	for _, provider in ipairs(all) do
		local target, err = provider.resolver.resolve(cleaned, parsed)
		if target then
			return target
		end
		resolve_err = resolve_err or err
	end

	return nil, resolve_err or (parsed and "Unsupported Atlas URL") or parse_err or "Unsupported Atlas target"
end

---@param domain "pulls"|"issues"
---@return AtlasProvider[]
function M.configured(domain)
	local result = {}
	for _, provider in ipairs(M.list(domain)) do
		if config.provider_options(provider.id) ~= nil then
			table.insert(result, provider)
		end
	end
	return result
end

add({
	id = "jira",
	name = "Jira",
	resolver = require("atlas.providers.jira.resolve"),
	domains = {
		issues = {
			module = "atlas.issues.providers.jira",
			icon = { icon = "󰌃", hl_group = "AtlasJiraTheme" },
			bookmark_key = "J",
			bookmark_label = "JQL",
		},
	},
})

add({
	id = "github",
	name = "GitHub",
	resolver = require("atlas.providers.github.resolve"),
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
	resolver = require("atlas.providers.bitbucket.resolve"),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.bitbucket",
			icon = { icon = "", hl_group = "AtlasBitbucketTheme" },
			bookmark_key = "S",
		},
	},
})

add({
	id = "gitlab",
	name = "GitLab",
	resolver = require("atlas.providers.gitlab.resolve"),
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

add({
	id = "gitea",
	name = "Gitea",
	resolver = require("atlas.providers.gitea.resolve"),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitea",
			icon = { icon = "", hl_group = "AtlasGiteaTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitea",
			icon = { icon = "", hl_group = "AtlasGiteaTheme" },
			bookmark_key = "S",
		},
	},
})

add({
	id = "forgejo",
	name = "Forgejo",
	resolver = require("atlas.providers.forgejo.resolve"),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.forgejo",
			icon = { icon = "", hl_group = "AtlasForgejoTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.forgejo",
			icon = { icon = "", hl_group = "AtlasForgejoTheme" },
			bookmark_key = "S",
		},
	},
})

return M
