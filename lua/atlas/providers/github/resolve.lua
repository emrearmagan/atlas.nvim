local M = {}

local url = require("atlas.providers.url")
local client = require("atlas.providers.github.client")

---@param parsed AtlasParsedUrl
---@param owner string
---@param repo string
---@return string, string, string
local function repository(parsed, owner, repo)
	local full_name = owner .. "/" .. repo
	local web_url = "https://" .. parsed.host .. "/" .. full_name
	return full_name, web_url, web_url .. ".git"
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil or parsed.host ~= client.hostname() then
		return nil, nil
	end

	local path = parsed.path
	if parsed.remote then
		path = path:gsub("%.git$", "")
	end
	local owner, repo = path:match("^/([^/]+)/([^/]+)$")
	if owner then
		local full_name, web_url, repository_url = repository(parsed, owner, repo)
		return {
			provider = "github",
			domain = "pulls",
			entity = "repo",
			url = web_url,
			repository_url = repository_url,
			host = parsed.host,
			owner = owner,
			repo = repo,
			repo_full_name = full_name,
		}
	end
	if parsed.remote then
		return nil, "Unsupported GitHub remote. Expected owner/repository"
	end

	local number, tail
	owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull/(%d+)(.*)$")
	local domain, entity = "pulls", "pr"
	if owner == nil then
		owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
		domain, entity = "issues", "issue"
	end
	if owner == nil then
		owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/actions/runs/(%d+)(.*)$")
		domain, entity = "pulls", "pipeline"
	end
	if owner then
		if not url.valid_tail(tail) then
			return nil, "Unsupported GitHub URL"
		end
		local id = assert(tonumber(number))
		local full_name, _, repository_url = repository(parsed, owner, repo)
		return {
			provider = "github",
			domain = domain,
			entity = entity,
			url = value,
			repository_url = repository_url,
			host = parsed.host,
			owner = owner,
			repo = repo,
			repo_full_name = full_name,
			id = entity ~= "issue" and id or nil,
			number = id,
		}
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, pull request, or pipeline URL"
end
return M
