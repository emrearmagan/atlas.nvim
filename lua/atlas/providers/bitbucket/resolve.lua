local M = {}

local url = require("atlas.providers.url")

local ROUTES = {
	{ path = "/pull%-requests/(%d+)", entity = "pr" },
	{ path = "/pipelines/results/(%d+)", entity = "pipeline" },
	{ path = "/pull%-requests", page = "pulls" },
	{ path = "/branches", page = "branches" },
	{ path = "/pipelines", page = "builds" },
}

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end

	local host = parsed.host
	-- Bitbucket Cloud moved SSH to ssh.bitbucket.org
	-- https://community.atlassian.com/forums/discussion/3234032/upcoming-change-to-bitbucket-cloud-ssh-access-move-from-bitbucket-org-to-ssh-bitbucket-org
	if parsed.remote and host == "ssh.bitbucket.org" then
		host = "bitbucket.org"
	end

	if host ~= "bitbucket.org" then
		local project, repo, number, tail =
			parsed.path:match("^/projects/([^/]+)/repos/([^/]+)/pull%-requests/(%d+)(.*)$")
		local server_pr = project and repo and number and url.valid_tail(tail)
		local server_repo = parsed.path:match("^/projects/[^/]+/repos/[^/]+$")

		if server_pr or server_repo then
			return nil,
				"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only"
		end
		return nil, nil
	end

	local path = parsed.path
	if parsed.remote then
		path = path:gsub("%.git$", "")
	end

	local workspace, repo, rest = path:match("^/([^/]+)/([^/]+)(.*)$")
	if parsed.remote and (workspace == nil or rest ~= "") then
		return nil, "Unsupported Bitbucket remote. Expected workspace/repository"
	end
	if workspace == nil then
		return nil, "Unsupported Bitbucket URL. Expected a Cloud repository, pull request, or pipeline URL"
	end

	local full_name = workspace .. "/" .. repo
	local web_url = url.base_url("bitbucket", host) .. "/" .. full_name
	---@type AtlasTarget
	local target = {
		provider = "bitbucket",
		domain = "pulls",
		entity = "repo",
		url = web_url,
		repository_url = web_url .. ".git",
		host = host,
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
				return nil, "Unsupported Bitbucket URL"
			end

			return vim.tbl_extend("force", target, {
				entity = route.entity or "repo",
				url = value,
				id = route.entity and tonumber(captures[1]) or captures[1],
				page = route.page,
			})
		end
	end

	return nil, "Unsupported Bitbucket URL. Expected a Cloud repository, pull request, or pipeline URL"
end

return M
