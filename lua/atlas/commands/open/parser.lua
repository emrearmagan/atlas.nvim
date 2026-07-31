local M = {}

---@alias AtlasOpenProvider "github"|"gitlab"|"bitbucket"|"jira"
---@alias AtlasOpenDomain "pulls"|"issues"
---@alias AtlasOpenEntity "pr"|"issue"|"repo"

---@class AtlasOpenTarget
---@field provider AtlasOpenProvider
---@field domain AtlasOpenDomain
---@field entity AtlasOpenEntity
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
---@field issue_key string|nil
---@field number integer|nil
---@field repo_slug string|nil

---@param value string|nil
---@return string
local function clean_input(value)
	local clean = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if clean:sub(1, 1) == "<" and clean:sub(-1) == ">" then
		return clean:sub(2, -2)
	end
	return clean
end

---@param value string
---@return string
local function decode(value)
	return (value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

---@param value string|nil
---@return AtlasParsedUrl|nil, string|nil
local function parse_url(value)
	local url = clean_input(value)
	if url == "" then
		return nil, "Missing URL"
	end

	local host, path = url:match("^https?://([^/?#]+)([^?#]*)")
	if host == nil then
		return nil, "Expected an http(s) URL"
	end

	path = decode(path or ""):gsub("/+$", "")
	return { host = host:lower(), path = path }, nil
end

---@param domain "pulls"|"issues"
---@param provider string
---@return table|nil
local function provider_config(domain, provider)
	local ok, config = pcall(require, "atlas.config")
	if not ok or type(config.options) ~= "table" then
		return nil
	end

	local domain_config = config.options[domain]
	local providers = type(domain_config) == "table" and domain_config.providers or nil
	local result = type(providers) == "table" and providers[provider] or nil
	return type(result) == "table" and result or nil
end

---@param domain "pulls"|"issues"
---@param provider string
---@return AtlasUrlBase|nil
local function configured_base(domain, provider)
	local config = provider_config(domain, provider)
	if type(config) ~= "table" or type(config.base_url) ~= "string" then
		return nil
	end

	local parsed = parse_url(config.base_url)
	return parsed and { host = parsed.host, path = parsed.path } or nil
end

---@param parsed AtlasParsedUrl
---@param base AtlasUrlBase|nil
---@return string|nil
local function path_for_base(parsed, base)
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
local function valid_tail(tail)
	return tail == nil or tail == "" or tail:sub(1, 1) == "/"
end

---@param project_path string|nil
---@return string|nil, string|nil
local function split_project(project_path)
	if project_path == nil then
		return nil, nil
	end
	local owner, repo = project_path:match("^(.+)/([^/]+)$")
	if owner == "" or repo == "" then
		return nil, nil
	end
	return owner, repo
end

---@param provider AtlasOpenProvider
---@param domain AtlasOpenDomain
---@param entity AtlasOpenEntity
---@param url string
---@param parsed AtlasParsedUrl
---@param fields table|nil
---@return AtlasOpenTarget
local function target(provider, domain, entity, url, parsed, fields)
	local result = fields or {}
	result.provider = provider
	result.domain = domain
	result.entity = entity
	result.url = url
	result.host = parsed.host
	return result
end

---@param parsed AtlasParsedUrl
---@param url string
---@return AtlasOpenTarget|nil, string|nil
local function parse_github(parsed, url)
	if parsed.host ~= "github.com" then
		return nil, nil
	end

	local owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull/(%d+)(.*)$")
	if owner ~= nil then
		if not valid_tail(tail) then
			return nil, "Unsupported GitHub pull request URL"
		end
		return target("github", "pulls", "pr", url, parsed, {
			owner = owner,
			repo = repo,
			number = tonumber(number),
		}),
			nil
	end

	owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
	if owner ~= nil then
		if not valid_tail(tail) then
			return nil, "Unsupported GitHub issue URL"
		end
		return target("github", "issues", "issue", url, parsed, {
			owner = owner,
			repo = repo,
			number = tonumber(number),
		}),
			nil
	end

	owner, repo = parsed.path:match("^/([^/]+)/([^/]+)$")
	if owner ~= nil then
		return target("github", "pulls", "repo", url, parsed, { owner = owner, repo = repo }), nil
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, or pull request URL"
end

---@param parsed AtlasParsedUrl
---@param url string
---@return AtlasOpenTarget|nil, string|nil
local function parse_jira(parsed, url)
	local path = path_for_base(parsed, configured_base("issues", "jira"))
	if path == nil then
		return nil, nil
	end

	local issue_key, tail = path:match("^/browse/([A-Z][A-Z0-9_]*%-%d+)(.*)$")
	if issue_key == nil or not valid_tail(tail) then
		return nil, "Unsupported Jira URL. Expected a /browse/KEY issue URL"
	end

	return target("jira", "issues", "issue", url, parsed, { issue_key = issue_key }), nil
end

---@param parsed AtlasParsedUrl
---@param url string
---@return AtlasOpenTarget|nil, string|nil
local function parse_gitlab(parsed, url)
	local pulls_path = path_for_base(parsed, configured_base("pulls", "gitlab"))
	local issues_path = path_for_base(parsed, configured_base("issues", "gitlab"))

	if pulls_path ~= nil then
		local project_path, number, tail = pulls_path:match("^/(.-)/%-/merge_requests/(%d+)(.*)$")
		local owner, repo = split_project(project_path)
		if owner ~= nil then
			if not valid_tail(tail) then
				return nil, "Unsupported GitLab merge request URL"
			end
			return target("gitlab", "pulls", "pr", url, parsed, {
				owner = owner,
				repo = repo,
				project_path = project_path,
				number = tonumber(number),
			}),
				nil
		end
	end

	if issues_path ~= nil then
		local project_path, number, tail = issues_path:match("^/(.-)/%-/issues/(%d+)(.*)$")
		local owner, repo = split_project(project_path)
		if owner ~= nil then
			if not valid_tail(tail) then
				return nil, "Unsupported GitLab issue URL"
			end
			return target("gitlab", "issues", "issue", url, parsed, {
				owner = owner,
				repo = repo,
				project_path = project_path,
				number = tonumber(number),
			}),
				nil
		end
	end

	if pulls_path ~= nil and not pulls_path:find("/-/", 1, true) then
		local project_path = pulls_path:match("^/(.+/.+)$")
		local owner, repo = split_project(project_path)
		if owner ~= nil then
			return target("gitlab", "pulls", "repo", url, parsed, {
				owner = owner,
				repo = repo,
				project_path = project_path,
			}),
				nil
		end
	end

	if pulls_path ~= nil or issues_path ~= nil then
		return nil, "Unsupported GitLab URL. Expected a repository, issue, or merge request URL"
	end
	return nil, nil
end

---@param parsed AtlasParsedUrl
---@param url string
---@return AtlasOpenTarget|nil, string|nil
local function parse_bitbucket(parsed, url)
	if parsed.host == "bitbucket.org" then
		local workspace, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull%-requests/(%d+)(.*)$")
		if workspace ~= nil then
			if not valid_tail(tail) then
				return nil, "Unsupported Bitbucket pull request URL"
			end
			return target("bitbucket", "pulls", "pr", url, parsed, {
				workspace = workspace,
				owner = workspace,
				repo = repo,
				number = tonumber(number),
			}),
				nil
		end

		workspace, repo = parsed.path:match("^/([^/]+)/([^/]+)$")
		if workspace ~= nil then
			return target("bitbucket", "pulls", "repo", url, parsed, {
				workspace = workspace,
				owner = workspace,
				repo = repo,
			}),
				nil
		end

		return nil, "Unsupported Bitbucket URL. Expected a Cloud repository or pull request URL"
	end

	local project, repo, number, tail = parsed.path:match("^/projects/([^/]+)/repos/([^/]+)/pull%-requests/(%d+)(.*)$")
	local is_server_pr = project ~= nil and repo ~= nil and number ~= nil and valid_tail(tail)
	local is_server_repo = parsed.path:match("^/projects/[^/]+/repos/[^/]+$") ~= nil
	if is_server_pr or is_server_repo then
		return nil,
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only"
	end

	return nil, nil
end

local parsers = { parse_github, parse_jira, parse_gitlab, parse_bitbucket }

---@param url string
---@return AtlasOpenTarget|nil, string|nil
function M.parse(url)
	local clean = clean_input(url)
	local parsed, err = parse_url(clean)
	if parsed == nil then
		return nil, err
	end

	for _, parse in ipairs(parsers) do
		local result, parse_err = parse(parsed, clean)
		if result ~= nil or parse_err ~= nil then
			return result, parse_err
		end
	end

	return nil, "Unsupported Atlas URL"
end

---@param value string
---@return AtlasOpenReference|nil
function M.parse_reference(value)
	local clean = clean_input(value)
	local issue_key = clean:upper():match("^([A-Z][A-Z0-9_]*%-%d+)$")
	if issue_key then
		return { issue_key = issue_key }
	end

	local repo_slug, repo_number = clean:match("^([%w._-]+/[%w._/-]+)#(%d+)$")
	if repo_slug then
		return { repo_slug = repo_slug, number = tonumber(repo_number) }
	end

	local number = clean:match("^#?(%d+)$")
	if number then
		return { number = tonumber(number) }
	end

	return nil
end

return M
