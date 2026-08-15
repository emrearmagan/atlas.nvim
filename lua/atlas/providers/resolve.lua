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

---@param value string
---@return AtlasParsedUrl|nil, string|nil
local function parse_url(value)
	if value == "" then
		return nil, "Missing URL"
	end

	local host, path = value:match("^https?://([^/?#]+)([^?#]*)")
	if host == nil then
		return nil, "Expected an http(s) URL"
	end

	path = (path or "")
		:gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)
		:gsub("/+$", "")
	return { host = host:lower(), path = path }
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

	local parsed = parse_url(options.base_url)
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

	local parsed, parse_err = parse_url(clean_value)
	local provider_list = providers.list()
	if parsed then
		local provider_id = M.provider_for_host(parsed.host)
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

---@param url string
---@return string|nil
local function url_host(url)
	return tostring(url or ""):lower():match("^https?://([^/]+)")
end

---@param provider AtlasProviderId
---@return string
local function provider_host(provider)
	for _, domain in ipairs({ "pulls", "issues" }) do
		local options = providers.options(provider, domain)
		local host = options and url_host(options.base_url) or nil
		if host then
			return host
		end
	end
	return providers[provider].default_host or ""
end

---Find the provider that owns a configured or well-known host.
---@param host string
---@return AtlasProviderId|nil
function M.provider_for_host(host)
	host = tostring(host or ""):lower()
	if host == "" then
		return nil
	end

	-- Configured URLs come first so self-hosted providers resolve correctly.
	for _, provider in ipairs(providers.list()) do
		for domain in pairs(provider.domains) do
			if url_host((providers.options(provider.id, domain) or {}).base_url) == host then
				return provider.id
			end
		end
	end

	for _, provider in ipairs(providers.list()) do
		local default_host = provider.default_host
		if default_host and (host == default_host or host:find(provider.id, 1, true)) then
			return provider.id
		end
	end
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
