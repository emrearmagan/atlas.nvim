local M = {}

local url = require("atlas.providers.url")
local client = require("atlas.providers.github.client")

local ROUTES = {
	{ path = "/pull/(%d+)/checks", entity = "pr", page = "builds" },
	{ path = "/pull/(%d+)", entity = "pr" },
	{ path = "/issues/(%d+)", entity = "issue" },
	{ path = "/actions/runs/(%d+)", entity = "pipeline" },
	{ path = "/discussions/(%d+)", page = "discussions" },
	{ path = "/releases/tag/(.+)", page = "releases" },
	{ path = "/issues", page = "issues" },
	{ path = "/pulls", page = "pulls" },
	{ path = "/discussions", page = "discussions" },
	{ path = "/actions", page = "builds", query = "branch:([^&+%s]+)" },
	{ path = "/releases", page = "releases" },
	{ path = "/tags", page = "tags" },
	{ path = "/branches", page = "branches" },
}

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
		repo_full_name = full_name,
	}
	if rest == "" then
		return target
	end

	for _, route in ipairs(ROUTES) do
		local captures = { rest:match("^" .. route.path .. "(.*)$") }
		if #captures > 0 then
			local tail = table.remove(captures)
			if not url.valid_tail(tail) then
				return nil, "Unsupported GitHub URL"
			end

			local id = captures[1]
			if route.query and parsed.query then
				id = parsed.query:match(route.query)
			end

			return vim.tbl_extend("force", target, {
				domain = route.entity == "issue" and "issues" or "pulls",
				entity = route.entity or "repo",
				url = value,
				id = route.entity and tonumber(id) or id,
				page = route.page,
			})
		end
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, pull request, or pipeline URL"
end

return M
