local M = {}

local url = require("atlas.providers.url")
local client = require("atlas.providers.github.client")

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
	local owner, repo, rest = path:match("^/([^/]+)/([^/]+)(.*)$")
	if parsed.remote and (owner == nil or rest ~= "") then
		return nil, "Unsupported GitHub remote. Expected owner/repository"
	end
	if owner == nil or owner == "orgs" then
		return nil, "Unsupported GitHub URL. Expected a repository, issue, pull request, or pipeline URL"
	end

	local full_name = owner .. "/" .. repo
	local web_url = "https://" .. parsed.host .. "/" .. full_name
	---@type AtlasTarget
	local target = {
		provider = "github",
		domain = "pulls",
		entity = "repo",
		url = web_url,
		repository_url = web_url .. ".git",
		host = parsed.host,
		owner = owner,
		repo = repo,
		repo_full_name = full_name,
	}

	local entity, number, tail = "pr", rest:match("^/pull/(%d+)(.*)$")
	if number == nil then
		entity, number, tail = "issue", rest:match("^/issues/(%d+)(.*)$")
	end
	if number == nil then
		entity, number, tail = "pipeline", rest:match("^/actions/runs/(%d+)(.*)$")
	end
	if number then
		if not url.valid_tail(tail) then
			return nil, "Unsupported GitHub URL"
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
		pulls = "pulls",
		discussions = "discussions",
		actions = "builds",
		releases = "releases",
		tags = "tags",
		branches = "branches",
	})[rest:match("^/([^/]+)") or ""]
	if rest == "" or target.page then
		return target
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, pull request, or pipeline URL"
end
return M
