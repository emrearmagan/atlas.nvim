local M = {}

local PROVIDER_MODULES = {
	pulls = {
		github = "atlas.pulls.providers.github",
		gitlab = "atlas.pulls.providers.gitlab",
		bitbucket = "atlas.pulls.providers.bitbucket",
	},
	issues = {
		github = "atlas.issues.providers.github",
		gitlab = "atlas.issues.providers.gitlab",
		jira = "atlas.issues.providers.jira",
	},
}

---@param domain AtlasOpenDomain
---@param provider AtlasOpenProvider
---@return table|nil
function M.provider_options(domain, provider)
	local config = require("atlas.config")
	local domain_options = config.options and config.options[domain] or nil
	local providers = type(domain_options) == "table" and domain_options.providers or nil
	local options = type(providers) == "table" and providers[provider] or nil
	return type(options) == "table" and options or nil
end

---@param target AtlasOpenTarget
---@return boolean
function M.provider_configured(target)
	return M.provider_options(target.domain, target.provider) ~= nil
end

---@param target AtlasOpenTarget
---@return PullsProvider|IssuesProvider|nil
function M.load_provider(target)
	local module = PROVIDER_MODULES[target.domain] and PROVIDER_MODULES[target.domain][target.provider] or nil
	return module and require(module) or nil
end

---@param target AtlasOpenTarget
---@return PullRequest
function M.pull_request_from_target(target)
	local owner = tostring(target.owner or target.workspace or "")
	local repo = tostring(target.repo or "")
	local full_name = target.project_path or (owner ~= "" and owner .. "/" .. repo or repo)
	local number = assert(target.number, "PR target missing number")
	return {
		id = number,
		title = "#" .. tostring(number),
		description = "",
		state = "open",
		author = { name = "", id = "", username = "" },
		source = { branch = "", commit_hash = "" },
		destination = { branch = "", commit_hash = "" },
		comments_count = 0,
		tasks_count = 0,
		created_on = "",
		updated_on = "",
		link = { html = target.url },
		provider = target.provider,
		workspace = owner,
		repo = repo,
		repo_full_name = full_name,
		_raw = target.provider == "gitlab" and { project_path = target.project_path, iid = number } or {},
	}
end

---@param target AtlasOpenTarget
---@return string
function M.base_url(target)
	local options = M.provider_options(target.domain, target.provider) or {}
	local configured = type(options.base_url) == "string" and options.base_url:gsub("/+$", "") or nil
	if configured and configured ~= "" then
		return configured
	end
	if target.provider == "github" then
		return "https://github.com"
	end
	if target.provider == "bitbucket" then
		return "https://bitbucket.org"
	end
	return "https://" .. target.host
end

---@param info AtlasGitRemoteInfo
---@param domain AtlasOpenDomain
---@param entity AtlasOpenEntity
---@param number integer
---@return AtlasOpenTarget
function M.target(info, domain, entity, number)
	local owner, repo = info.slug:match("^(.+)/([^/]+)$")
	local target = {
		provider = info.provider,
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		project_path = info.provider == "gitlab" and info.slug or nil,
		workspace = info.provider == "bitbucket" and owner or nil,
		number = number,
	}
	local base = M.base_url(target)
	if info.provider == "github" then
		target.url = string.format("%s/%s/%s/%s/%d", base, owner, repo, entity == "pr" and "pull" or "issues", number)
	elseif info.provider == "gitlab" then
		target.url =
			string.format("%s/%s/-/%s/%d", base, info.slug, entity == "pr" and "merge_requests" or "issues", number)
	else
		target.url = string.format("%s/%s/pull-requests/%d", base, info.slug, number)
	end
	return target
end

---@param provider AtlasOpenProvider
---@return string
local function provider_host(provider)
	if provider == "github" then
		return "github.com"
	end
	if provider == "bitbucket" then
		return "bitbucket.org"
	end
	for _, domain in ipairs({ "pulls", "issues" }) do
		local options = M.provider_options(domain, provider)
		local host = options and tostring(options.base_url or ""):match("^https?://([^/]+)") or nil
		if host then
			return host
		end
	end
	return "gitlab.com"
end

---@param provider AtlasOpenProvider
---@param slug string
---@return AtlasGitRemoteInfo
local function repo_info(provider, slug)
	local owner, repo = slug:match("^([^/]+)/(.+)$")
	return {
		provider = provider,
		host = provider_host(provider),
		slug = slug,
		owner = owner,
		repo = repo,
		url = "",
	}
end

---@return AtlasGitRemoteInfo[]
local function configured_repositories()
	local found, seen = {}, {}
	local function add(provider, slug)
		slug = type(slug) == "string" and slug or ""
		local key = provider .. ":" .. slug
		if slug:match("^[^/]+/.+$") and not seen[key] then
			seen[key] = true
			table.insert(found, repo_info(provider, slug))
		end
	end

	for _, domain in ipairs({ "pulls", "issues" }) do
		for _, provider in ipairs({ "github", "gitlab", "bitbucket" }) do
			local options = M.provider_options(domain, provider)
			for _, view in ipairs((options and options.views) or {}) do
				if provider == "github" then
					for slug in tostring(view.search or ""):gmatch("repo:([%w._/-]+)") do
						add(provider, slug)
					end
				elseif provider == "gitlab" then
					add(provider, view.project)
				else
					for _, repo in ipairs(view.repos or {}) do
						add(provider, tostring(repo.workspace or "") .. "/" .. tostring(repo.repo or ""))
					end
				end
			end
		end
	end
	return found
end

---@return AtlasGitRemoteInfo|nil
function M.local_repository()
	local git = require("atlas.core.git")
	local root = git.repo_root()
	local remote_url = root and git.remote_url(root, "origin") or nil
	local info = remote_url and git.parse_remote_url(remote_url) or nil
	if info and info.provider == "unknown" then
		for _, domain in ipairs({ "pulls", "issues" }) do
			local options = M.provider_options(domain, "gitlab")
			local host = options and tostring(options.base_url or ""):match("^https?://([^/]+)") or nil
			if host == info.host then
				info.provider = "gitlab"
				break
			end
		end
	end
	return info and info.provider ~= "unknown" and info or nil
end

---@param repo_slug string|nil
---@return AtlasGitRemoteInfo[]
function M.configured_repositories(repo_slug)
	local choices = {}
	for _, candidate in ipairs(configured_repositories()) do
		if repo_slug == nil or candidate.slug == repo_slug then
			table.insert(choices, candidate)
		end
	end

	if repo_slug and #choices == 0 then
		for _, provider in ipairs({ "github", "gitlab", "bitbucket" }) do
			if
				M.provider_options("pulls", provider)
				or (provider ~= "bitbucket" and M.provider_options("issues", provider))
			then
				table.insert(choices, repo_info(provider, repo_slug))
			end
		end
	end
	return choices
end

return M
