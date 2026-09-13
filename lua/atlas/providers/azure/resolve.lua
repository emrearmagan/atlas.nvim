local M = {}

local url = require("atlas.providers.url")

---@param value string
---@return string
local function encode(value)
	return (value:gsub("([^%w%-_.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end

	local path = parsed.path
	local organization, project, repo, number, issue_number, tail
	if parsed.host == "ssh.dev.azure.com" then
		organization, project, repo = path:match("^/v3/([^/]+)/([^/]+)/([^/]+)$")
		if organization == nil then
			return nil, "Unsupported Azure DevOps remote. Expected v3/organization/project/repository"
		end
	elseif parsed.host == "dev.azure.com" then
		organization, project, issue_number, tail = path:match("^/([^/]+)/([^/]+)/_workitems/edit/(%d+)(.*)$")
		if organization == nil then
			organization, project, repo, number, tail =
				path:match("^/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(%d+)(.*)$")
		end
		if organization == nil then
			organization, project, repo = path:match("^/([^/]+)/([^/]+)/_git/([^/]+)$")
		end
		if organization == nil then
			return nil, "Unsupported Azure DevOps URL. Expected a repository, pull request, or work item URL"
		end
	else
		return nil, nil
	end

	if (number or issue_number) and not url.valid_tail(tail) then
		return nil, "Unsupported Azure DevOps URL"
	end
	local base = url.configured_base("azure")
	if base and base.path:lower() ~= "/" .. organization:lower() then
		return nil, "Azure DevOps URL organization does not match providers.azure.base_url"
	end
	if issue_number then
		return {
			provider = "azure",
			domain = "issues",
			entity = "issue",
			url = value,
			host = "dev.azure.com",
			organization = organization,
			owner = project,
			project_path = project,
			id = tonumber(issue_number),
			number = tonumber(issue_number),
			issue_key = issue_number,
		}
	end

	local full_name = project .. "/" .. repo
	local web_url =
		string.format("https://dev.azure.com/%s/%s/_git/%s", encode(organization), encode(project), encode(repo))
	local id = number and assert(tonumber(number)) or nil
	return {
		provider = "azure",
		domain = "pulls",
		entity = id and "pr" or "repo",
		url = id and value or web_url,
		repository_url = web_url,
		host = "dev.azure.com",
		organization = organization,
		owner = project,
		repo = repo,
		project_path = full_name,
		repo_full_name = full_name,
		id = id,
		number = id,
	}
end

return M
