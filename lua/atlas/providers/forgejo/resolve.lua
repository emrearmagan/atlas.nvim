local M = {}

local url = require("atlas.providers.url")

---@param parsed AtlasParsedUrl
---@param owner string
---@param repo string
---@return string, string, string
local function repository(parsed, owner, repo)
	local full_name = owner .. "/" .. repo
	local web_url = url.base_url("forgejo", parsed.host) .. "/" .. full_name
	return full_name, web_url, web_url .. ".git"
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local base = url.configured_base("forgejo")
	if base == nil or parsed.host ~= base.host then
		return nil, nil
	end
	local path = url.path(parsed, base)
	if path == nil and parsed.remote then
		path = parsed.path
	end
	if path == nil then
		return nil, nil
	end

	if parsed.remote then
		path = path:gsub("%.git$", "")
		local owner, repo = path:match("^/([^/]+)/([^/]+)$")
		if owner == nil then
			return nil, "Unsupported Forgejo remote. Expected owner/repository"
		end
		local full_name, web_url, repository_url = repository(parsed, owner, repo)
		return {
			provider = "forgejo",
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

	local owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/pulls/(%d+)(.*)$")
	local domain, entity = "pulls", "pr"
	if owner == nil then
		owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/issues/(%d+)(.*)$")
		domain, entity = "issues", "issue"
	end
	if owner then
		if not url.valid_tail(tail) then
			return nil, "Unsupported Forgejo URL"
		end
		local id = assert(tonumber(number))
		local full_name, _, repository_url = repository(parsed, owner, repo)
		return {
			provider = "forgejo",
			domain = domain,
			entity = entity,
			url = value,
			repository_url = repository_url,
			host = parsed.host,
			owner = owner,
			repo = repo,
			repo_full_name = full_name,
			id = entity == "pr" and id or nil,
			number = id,
			issue_key = entity == "issue" and string.format("%s#%d", full_name, id) or nil,
		}
	end

	owner, repo = path:match("^/([^/]+)/([^/]+)$")
	if owner then
		local full_name, web_url, repository_url = repository(parsed, owner, repo)
		return {
			provider = "forgejo",
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

	return nil, "Unsupported Forgejo URL. Expected a repository, issue, or pull request URL"
end

return M
