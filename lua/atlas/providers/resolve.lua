local M = {}

local providers = require("atlas.providers")

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
---@field issue_key string|nil

---@class AtlasParsedUrl
---@field host string
---@field path string

---@class AtlasUrlBase
---@field host string
---@field path string

---@class AtlasOpenReference
---@field number integer
---@field repo_slug string|nil

---@param value string|nil
---@return string
local function clean(value)
	local result = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if result:sub(1, 1) == "<" and result:sub(-1) == ">" then
		return result:sub(2, -2)
	end
	return result
end

---@param path string
---@return string
local function decode_path(path)
	return (path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

---@param value string
---@return AtlasParsedUrl|nil, string|nil
function M.parse_url(value)
	if value == "" then
		return nil, "Missing URL"
	end

	local scheme, host, path = value:match("^(https?)://([^/?#]+)([^?#]*)")
	if host == nil then
		return nil, "Expected an http(s) URL"
	end

	host = host:lower()
	if scheme == "http" then
		host = host:gsub(":80$", "")
	elseif scheme == "https" then
		host = host:gsub(":443$", "")
	end
	path = decode_path(path or ""):gsub("/+$", "")
	return { host = host, path = path }
end

---Return the configured provider URL as a parsed host and path.
---@param domain AtlasDomain
---@param provider AtlasProviderId
---@return AtlasUrlBase|nil
function M.configured_base(domain, provider)
	local options = providers.options(provider, domain)
	if type(options) ~= "table" or type(options.base_url) ~= "string" then
		return nil
	end

	local parsed = M.parse_url(options.base_url)
	return parsed and { host = parsed.host, path = parsed.path } or nil
end

---Strip a configured base path from a parsed URL.
---@param parsed AtlasParsedUrl
---@param base AtlasUrlBase|nil
---@return string|nil
function M.path_for_base(parsed, base)
	if base == nil or parsed.host ~= base.host then
		return nil
	end
	if base.path == "" then
		return parsed.path
	end
	if parsed.path == base.path then
		return ""
	end
	if parsed.path:sub(1, #base.path + 1) == base.path .. "/" then
		return parsed.path:sub(#base.path + 1)
	end
	return nil
end

---@param tail string|nil
---@return boolean
function M.valid_tail(tail)
	return tail == nil or tail == "" or tail:sub(1, 1) == "/"
end

---Split a nested project path into its owner and repository.
---@param project_path string|nil
---@return string|nil, string|nil
function M.split_project(project_path)
	if project_path == nil then
		return nil, nil
	end
	return project_path:match("^(.+)/([^/]+)$")
end

---Resolve a URL, provider reference, or numeric reference.
---@param value string
---@return AtlasTarget|AtlasOpenReference|nil, string|nil
function M.resolve(value)
	local clean_value = clean(value)
	local repo_slug, repo_number = clean_value:match("^([%w._-]+/[%w._/-]+)#(%d+)$")
	if repo_slug then
		return { repo_slug = repo_slug, number = tonumber(repo_number) }
	end

	local number = clean_value:match("^#?(%d+)$")
	if number then
		return { number = tonumber(number) }
	end

	local parsed, parse_err = M.parse_url(clean_value)
	local provider_list = providers.list()
	if parsed then
		local provider_id = M.provider_for_host(parsed.host, parsed.path)
		if provider_id == nil then
			return nil, "Unsupported Atlas URL"
		end
		provider_list = { providers[provider_id] }
	end

	local resolve_err
	for _, provider in ipairs(provider_list) do
		for _, domain in ipairs({ "pulls", "issues" }) do
			if provider.domains[domain] then
				local implementation = assert(providers.load(provider.id, domain))
				local target, current_err = implementation.resolve(clean_value, parsed)
				if target then
					return target
				end
				resolve_err = resolve_err or current_err
			end
		end
	end

	return nil, resolve_err or parse_err or "Unsupported Atlas target"
end

---@param host string|nil
---@return string
local function hostname(host)
	host = tostring(host or ""):lower()
	if host:sub(1, 1) == "[" then
		return host:match("^%[([^%]]+)%]") or host
	end
	return host:match("^([^:]+):%d+$") or host
end

---@param provider AtlasProviderId
---@return string
local function provider_host(provider)
	for _, domain in ipairs({ "pulls", "issues" }) do
		local base = M.configured_base(domain, provider)
		if base then
			return base.host
		end
	end
	return providers[provider].default_host or ""
end

---@param host string
---@param path string|nil
---@param ignore_port boolean
---@return AtlasProviderId|nil, AtlasUrlBase|nil
local function configured_provider(host, path, ignore_port)
	for _, provider in ipairs(providers.list()) do
		for _, domain in ipairs({ "pulls", "issues" }) do
			if provider.domains[domain] then
				local base = M.configured_base(domain, provider.id)
				local host_matches = base and base.host == host
				if ignore_port and base then
					host_matches = hostname(base.host) == hostname(host)
				end
				if host_matches and (path == nil or M.path_for_base({ host = host, path = path }, base) ~= nil) then
					return provider.id, base
				end
			end
		end
	end
end

---Find the provider that owns a configured or well-known host.
---@param host string
---@param path string|nil
---@return AtlasProviderId|nil
function M.provider_for_host(host, path)
	host = tostring(host or ""):lower()
	if host == "" then
		return nil
	end
	path = path and decode_path(path) or nil

	-- Configured URLs come first so self-hosted providers resolve correctly.
	local configured = configured_provider(host, path, false)
	if configured then
		return configured
	end

	for _, provider in ipairs(providers.list()) do
		local default_host = provider.default_host
		if default_host and (host == default_host or host:find(provider.id, 1, true)) then
			return provider.id
		end
	end
end

---@class AtlasResolvedGitRemote
---@field provider AtlasProviderId|nil
---@field host string Canonical web authority.
---@field repository_path string

---Resolve a Git remote to its provider, canonical web host, and repository path.
---@param host string
---@param repository_path string
---@param is_http boolean
---@return AtlasResolvedGitRemote
function M.resolve_git_remote(host, repository_path, is_http)
	host = tostring(host or ""):lower()
	repository_path = tostring(repository_path or ""):gsub("^/+", ""):gsub("/+$", "")

	if is_http then
		local parsed_path = "/" .. decode_path(repository_path)
		local provider, base = configured_provider(host, parsed_path, false)
		if provider and base then
			local path = assert(M.path_for_base({ host = host, path = parsed_path }, base))
			return { provider = provider, host = base.host, repository_path = path:gsub("^/+", "") }
		end
		return {
			provider = M.provider_for_host(host, "/" .. repository_path),
			host = host,
			repository_path = decode_path(repository_path),
		}
	end

	local provider, base = configured_provider(host, nil, true)
	if provider and base then
		return { provider = provider, host = base.host, repository_path = repository_path }
	end
	local canonical_host = hostname(host)
	return {
		provider = M.provider_for_host(canonical_host),
		host = canonical_host,
		repository_path = repository_path,
	}
end

---@param target AtlasTarget
---@return boolean
function M.configured(target)
	return providers.domain(target.provider, target.domain) ~= nil
		and providers.options(target.provider, target.domain) ~= nil
end

---Build the minimal pull request identity needed for a provider fetch.
---@param target AtlasTarget
---@return PullRequestRef
function M.pull_request_ref(target)
	local owner = tostring(target.owner or target.workspace or "")
	local repo = tostring(target.repo or "")
	return {
		id = assert(target.number, "PR target missing number"),
		repo_full_name = target.project_path or (owner ~= "" and owner .. "/" .. repo or repo),
	}
end

---Return the configured provider URL, falling back to the target's host.
---@param target { provider: AtlasProviderId, domain: AtlasDomain, host: string }
---@return string
function M.base_url(target)
	local options = providers.options(target.provider, target.domain) or {}
	local configured = type(options.base_url) == "string" and options.base_url:gsub("/+$", "") or nil
	if configured and configured ~= "" then
		return configured
	end
	local host = target.host ~= "" and target.host or provider_host(target.provider)
	return "https://" .. host
end

---Build a provider target from a Git remote.
---@param info AtlasGitRemoteInfo
---@param domain AtlasDomain
---@param entity AtlasEntity
---@param number integer|nil
---@return AtlasTarget
function M.target(info, domain, entity, number)
	local partial = { provider = info.provider, domain = domain, host = info.host }
	return assert(providers.load(info.provider, domain)).target(info, domain, entity, number, M.base_url(partial))
end

---@param provider AtlasProviderId
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

---Find configured repositories that can resolve a numeric reference.
---@param repo_slug string|nil
---@return AtlasGitRemoteInfo[]
function M.configured_repositories(repo_slug)
	local choices, seen = {}, {}
	for _, provider in ipairs(providers.list()) do
		for _, domain in ipairs({ "pulls", "issues" }) do
			local options = providers.options(provider.id, domain)
			local implementation = options and providers.load(provider.id, domain) or nil
			if implementation and options and implementation.repositories then
				for _, slug in ipairs(implementation.repositories(options)) do
					local key = provider.id .. ":" .. tostring(slug)
					if
						type(slug) == "string"
						and slug:match("^[^/]+/.+$")
						and (repo_slug == nil or slug == repo_slug)
						and not seen[key]
					then
						seen[key] = true
						table.insert(choices, repo_info(provider.id, slug))
					end
				end
			end
		end
	end

	if repo_slug and #choices == 0 then
		-- An explicit owner/repo does not need to appear in a configured view.
		for _, provider in ipairs(providers.list()) do
			for _, domain in ipairs({ "pulls", "issues" }) do
				local options = providers.options(provider.id, domain)
				local implementation = options and providers.load(provider.id, domain) or nil
				if implementation and implementation.target then
					table.insert(choices, repo_info(provider.id, repo_slug))
					break
				end
			end
		end
	end
	return choices
end

return M
