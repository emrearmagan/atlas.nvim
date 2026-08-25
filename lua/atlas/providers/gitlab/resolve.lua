local M = {}

local url = require("atlas.providers.url")

---@param project_path string|nil
---@return string|nil, string|nil
local function split_project(project_path)
	if project_path == nil then
		return nil, nil
	end
	return project_path:match("^(.+)/([^/]+)$")
end

---@param parsed AtlasParsedUrl
---@param project_path string
---@return string, string
local function repository(parsed, project_path)
	local web_url = url.base_url("gitlab", parsed.host, "gitlab.com") .. "/" .. project_path
	return web_url, web_url .. ".git"
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local base = url.configured_base("gitlab")
	if base == nil then
		base = { host = "gitlab.com", path = "", remote = false }
	end
	if parsed.host ~= base.host then
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
		local project_path = path:gsub("^/", ""):gsub("%.git$", "")
		local owner, repo = split_project(project_path)
		if owner == nil then
			return nil, "Unsupported GitLab remote. Expected group/repository"
		end
		local web_url, repository_url = repository(parsed, project_path)
		return {
			provider = "gitlab",
			domain = "pulls",
			entity = "repo",
			url = web_url,
			repository_url = repository_url,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = project_path,
			repo_full_name = project_path,
		}
	end

	local project_path, number, tail = path:match("^/(.-)/%-/merge_requests/(%d+)(.*)$")
	local domain, entity = "pulls", "pr"
	if project_path == nil then
		project_path, number, tail = path:match("^/(.-)/%-/issues/(%d+)(.*)$")
		domain, entity = "issues", "issue"
	end
	local owner, repo = split_project(project_path)
	if owner then
		if not url.valid_tail(tail) then
			return nil, "Unsupported GitLab URL"
		end
		local id = assert(tonumber(number))
		local _, repository_url = repository(parsed, project_path)
		return {
			provider = "gitlab",
			domain = domain,
			entity = entity,
			url = value,
			repository_url = repository_url,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = project_path,
			repo_full_name = project_path,
			id = entity == "pr" and id or nil,
			number = id,
		}
	end

	if not path:find("/-/", 1, true) then
		project_path = path:match("^/(.+/.+)$")
		owner, repo = split_project(project_path)
		if owner then
			local web_url, repository_url = repository(parsed, project_path)
			return {
				provider = "gitlab",
				domain = "pulls",
				entity = "repo",
				url = web_url,
				repository_url = repository_url,
				host = parsed.host,
				owner = owner,
				repo = repo,
				project_path = project_path,
				repo_full_name = project_path,
			}
		end
	end

	return nil, "Unsupported GitLab URL. Expected a repository, issue, or merge request URL"
end
return M
