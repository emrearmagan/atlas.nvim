local M = {}

local url = require("atlas.providers.url")
local utils = require("atlas.core.utils")

local ROUTES = {
	{ path = "/pullrequest/(%d+)", entity = "pr" },
	{ path = "/pullrequests", page = "pulls" },
	{ path = "/branches", page = "branches" },
	{ path = "/tags", page = "tags" },
}

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end

	local path = parsed.path
	if parsed.host == "ssh.dev.azure.com" then
		local organization, project, repo = path:match("^/v3/([^/]+)/([^/]+)/([^/]+)$")
		if organization == nil then
			return nil, "Unsupported Azure DevOps remote. Expected v3/organization/project/repository"
		end
		path = string.format("/%s/%s/_git/%s", organization, project, repo)
	elseif parsed.host ~= "dev.azure.com" then
		return nil, nil
	end

	local organization, project, rest = path:match("^/([^/]+)/([^/]+)(.*)$")
	if organization == nil then
		return nil, "Unsupported Azure DevOps URL. Expected a repository, pull request, or work item URL"
	end

	local base = url.configured_base("azure")
	if base and base.path:lower() ~= "/" .. organization:lower() then
		return nil, "Azure DevOps URL organization does not match providers.azure.base_url"
	end

	local work_item, work_item_tail = rest:match("^/_workitems/edit/(%d+)(.*)$")
	if work_item then
		if not url.valid_tail(work_item_tail) then
			return nil, "Unsupported Azure DevOps URL"
		end

		return {
			provider = "azure",
			domain = "issues",
			entity = "issue",
			url = value,
			host = "dev.azure.com",
			id = tonumber(work_item),
		}
	end

	local repo, repo_rest = rest:match("^/_git/([^/]+)(.*)$")
	if repo == nil then
		return nil, "Unsupported Azure DevOps URL. Expected a repository, pull request, or work item URL"
	end

	local web_url = string.format(
		"https://dev.azure.com/%s/%s/_git/%s",
		utils.url_encode(organization),
		utils.url_encode(project),
		utils.url_encode(repo)
	)
	---@type AtlasTarget
	local target = {
		provider = "azure",
		domain = "pulls",
		entity = "repo",
		url = web_url,
		repository_url = web_url,
		host = "dev.azure.com",
		repo_full_name = project .. "/" .. repo,
	}
	if repo_rest == "" then
		return target
	end

	for _, route in ipairs(ROUTES) do
		local captures = { repo_rest:match("^" .. route.path .. "(.*)$") }
		if #captures > 0 then
			local tail = table.remove(captures)
			if not url.valid_tail(tail) then
				return nil, "Unsupported Azure DevOps URL"
			end

			return vim.tbl_extend("force", target, {
				entity = route.entity or "repo",
				url = value,
				id = route.entity and tonumber(captures[1]) or captures[1],
				page = route.page,
			})
		end
	end

	return nil, "Unsupported Azure DevOps URL. Expected a repository, pull request, or work item URL"
end

return M
