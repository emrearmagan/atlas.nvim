local M = {}

local url = require("atlas.providers.url")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local base = url.configured_base("gitlab") or { host = "gitlab.com", path = "", remote = false }
	if parsed.host ~= base.host then
		return nil, nil
	end
	local path = url.relative_path(parsed, base)
	if path == nil and parsed.remote then
		path = parsed.path
	end
	if path == nil then
		return nil, nil
	end

	if parsed.remote then
		path = path:gsub("%.git$", "")
	end
	local project_path, rest = path:match("^/(.-)/%-(/.*)$")
	if project_path == nil then
		project_path, rest = path:sub(2), ""
	end
	local owner, repo = project_path:match("^(.+)/([^/]+)$")
	if parsed.remote and (owner == nil or rest ~= "") then
		return nil, "Unsupported GitLab remote. Expected group/repository"
	end
	if owner == nil or project_path:match("^groups/") then
		return nil, "Unsupported GitLab URL. Expected a repository, issue, merge request, or pipeline URL"
	end

	local web_url = url.base_url("gitlab", parsed.host) .. "/" .. project_path
	---@type AtlasTarget
	local target = {
		provider = "gitlab",
		domain = "pulls",
		entity = "repo",
		url = web_url,
		repository_url = web_url .. ".git",
		host = parsed.host,
		owner = owner,
		repo = repo,
		project_path = project_path,
		repo_full_name = project_path,
	}

	local entity, number, tail = "pr", rest:match("^/merge_requests/(%d+)(.*)$")
	if number == nil then
		entity, number, tail = "issue", rest:match("^/issues/(%d+)(.*)$")
	end
	if number == nil then
		entity, number, tail = "issue", rest:match("^/work_items/(%d+)(.*)$")
	end
	if number == nil then
		entity, number, tail = "pipeline", rest:match("^/pipelines/(%d+)(.*)$")
	end
	if number then
		if not url.valid_tail(tail) then
			return nil, "Unsupported GitLab URL"
		end
		target.domain = entity == "issue" and "issues" or "pulls"
		target.entity = entity
		target.url = value
		target.number = assert(tonumber(number))
		target.id = entity ~= "issue" and target.number or nil
		return target
	end

	target.page = ({
		issues = "issues",
		merge_requests = "pulls",
		pipelines = "builds",
		releases = "releases",
		tags = "tags",
		branches = "branches",
	})[rest:match("^/([^/]+)") or ""]
	if rest == "" or target.page then
		return target
	end

	return nil, "Unsupported GitLab URL. Expected a repository, issue, merge request, or pipeline URL"
end
return M
