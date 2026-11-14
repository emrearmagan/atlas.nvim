local M = {}

local url = require("atlas.providers.url")

local ROUTES = {
	{ path = "/merge_requests/(%d+)/pipelines", entity = "pr", page = "builds" },
	{ path = "/merge_requests/(%d+)", entity = "pr" },
	{ path = "/issues/(%d+)", entity = "issue" },
	{ path = "/work_items/(%d+)", entity = "issue" },
	{ path = "/pipelines/(%d+)", entity = "pipeline" },
	{ path = "/releases/(.+)", page = "releases" },
	{ path = "/issues", page = "issues" },
	{ path = "/merge_requests", page = "pulls" },
	{ path = "/pipelines", page = "builds" },
	{ path = "/releases", page = "releases" },
	{ path = "/tags", page = "tags" },
	{ path = "/branches", page = "branches" },
}

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

	local has_group = project_path:match("^.+/[^/]+$") ~= nil
	if parsed.remote and (not has_group or rest ~= "") then
		return nil, "Unsupported GitLab remote. Expected group/repository"
	end
	if not has_group or project_path:match("^groups/") then
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
		repo_full_name = project_path,
	}
	if rest == "" then
		return target
	end

	for _, route in ipairs(ROUTES) do
		local captures = { rest:match("^" .. route.path .. "(.*)$") }
		if #captures > 0 then
			local tail = table.remove(captures)
			if not url.valid_tail(tail) then
				return nil, "Unsupported GitLab URL"
			end

			return vim.tbl_extend("force", target, {
				domain = route.entity == "issue" and "issues" or "pulls",
				entity = route.entity or "repo",
				url = value,
				id = route.entity and tonumber(captures[1]) or captures[1],
				page = route.page,
			})
		end
	end

	return nil, "Unsupported GitLab URL. Expected a repository, issue, merge request, or pipeline URL"
end

return M
