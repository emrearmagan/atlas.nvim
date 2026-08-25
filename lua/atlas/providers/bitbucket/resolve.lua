local M = {}

local url = require("atlas.providers.url")

---@param parsed AtlasParsedUrl
---@param workspace string
---@param repo string
---@return string, string, string
local function repository(parsed, workspace, repo)
	local full_name = workspace .. "/" .. repo
	local web_url = url.base_url("bitbucket", parsed.host, "bitbucket.org") .. "/" .. full_name
	return full_name, web_url, web_url .. ".git"
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	if parsed.host == "bitbucket.org" then
		if parsed.remote then
			local path = parsed.path:gsub("%.git$", "")
			local workspace, repo = path:match("^/([^/]+)/([^/]+)$")
			if workspace == nil then
				return nil, "Unsupported Bitbucket remote. Expected workspace/repository"
			end
			local full_name, web_url, repository_url = repository(parsed, workspace, repo)
			return {
				provider = "bitbucket",
				domain = "pulls",
				entity = "repo",
				url = web_url,
				repository_url = repository_url,
				host = parsed.host,
				workspace = workspace,
				owner = workspace,
				repo = repo,
				repo_full_name = full_name,
			}
		end

		local workspace, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull%-requests/(%d+)(.*)$")
		if workspace then
			if not url.valid_tail(tail) then
				return nil, "Unsupported Bitbucket pull request URL"
			end
			local id = assert(tonumber(number))
			local full_name, _, repository_url = repository(parsed, workspace, repo)
			return {
				provider = "bitbucket",
				domain = "pulls",
				entity = "pr",
				url = value,
				repository_url = repository_url,
				host = parsed.host,
				workspace = workspace,
				owner = workspace,
				repo = repo,
				repo_full_name = full_name,
				id = id,
				number = id,
			}
		end

		workspace, repo = parsed.path:match("^/([^/]+)/([^/]+)$")
		if workspace then
			local full_name, web_url, repository_url = repository(parsed, workspace, repo)
			return {
				provider = "bitbucket",
				domain = "pulls",
				entity = "repo",
				url = web_url,
				repository_url = repository_url,
				host = parsed.host,
				workspace = workspace,
				owner = workspace,
				repo = repo,
				repo_full_name = full_name,
			}
		end

		return nil, "Unsupported Bitbucket URL. Expected a Cloud repository or pull request URL"
	end

	local project, repo, number, tail = parsed.path:match("^/projects/([^/]+)/repos/([^/]+)/pull%-requests/(%d+)(.*)$")
	local server_pr = project and repo and number and url.valid_tail(tail)
	local server_repo = parsed.path:match("^/projects/[^/]+/repos/[^/]+$")
	if server_pr or server_repo then
		return nil,
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only"
	end

	return nil, nil
end
return M
