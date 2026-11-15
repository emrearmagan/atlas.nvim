local M = {}

local config = require("atlas.config")
local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.jira.client")
local url_encode = require("atlas.core.utils").url_encode

---Extract Jira references from PR titles and source branches.
---@param ... string|nil
---@return AtlasLink[]
function M.resolve(...)
	local options = config.provider_options("jira") or {}
	local base_url = tostring(options.base_url or "")
	if not base_url:match("^https?://") then
		return {}
	end

	local links, seen = {}, {}
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		if type(value) == "string" then
			for key in value:gmatch("%f[%w_]([A-Z][A-Z0-9_]*%-%d+)%f[^%w_]") do
				if not seen[key] then
					seen[key] = true
					table.insert(links, {
						url = base_url .. "/browse/" .. key,
						key = key,
						relationship = "references",
					})
				end
			end
		end
	end
	return links
end

---@param links AtlasLink[]
---@param raw table|nil
---@param relationship AtlasRelationship
local function append_issue(links, raw, relationship)
	raw = json.safe_table(raw)
	local key = json.safe_str(raw.key)
	if not key or not key:match("^[A-Z][A-Z0-9_]*%-%d+$") then
		return
	end
	local fields = json.safe_table(raw.fields)
	table.insert(links, {
		url = service.base_url() .. "/browse/" .. key,
		key = key,
		title = json.safe_str(fields.summary),
		relationship = relationship,
	})
end

---@param issue_id string
---@param on_done fun(links: AtlasLink[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_development(issue_id, on_done)
	-- NOTE: As of now this only looks up Bitbucket PRs.
	-- To support more, we'd need to call /rest/dev-status/1.0/issue/summary first
	-- to get the application types from summary.pullrequest.byInstanceType.
	local endpoint = string.format(
		"/rest/dev-status/1.0/issue/detail?issueId=%s&applicationType=bitbucket&dataType=pullrequest",
		url_encode(issue_id)
	)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local links = {}
		for _, detail in ipairs(json.safe_table(result.detail)) do
			for _, pr in ipairs(json.safe_table(detail.pullRequests)) do
				local url = json.safe_str(pr.url)
				if url and url:match("^https?://") then
					table.insert(links, {
						url = url,
						key = json.safe_str(pr.id),
						title = json.safe_str(pr.name),
						relationship = "development",
					})
				end
			end
		end
		on_done(links, nil)
	end)
end

---@param _ "pr"|"issue"
---@param issue JiraIssue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasLink[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(_, issue, opts, on_done)
	local key = issue.key
	local cache_key = "jira:links:" .. service.base_url() .. ":" .. key
	if not (opts or {}).force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local requests = request_scope.new()
	requests.all({
		issues = function(done)
			return service.request("GET", "/issue/" .. key .. "?fields=parent,subtasks,issuelinks", nil, done)
		end,
		remote = function(done)
			return service.request("GET", "/issue/" .. key .. "/remotelink", nil, done)
		end,
		development = function(done)
			return fetch_development(issue.id, done)
		end,
	}, function(results, errors)
		local links = {}

		local fields = json.safe_table(json.safe_table(results.issues).fields)
		append_issue(links, fields.parent, "parent")
		for _, subtask in ipairs(json.safe_table(fields.subtasks)) do
			append_issue(links, subtask, "sub-issue")
		end
		for _, link in ipairs(json.safe_table(fields.issuelinks)) do
			local relationship = json.safe_table(link.type)
			append_issue(links, link.outwardIssue, json.safe_str(relationship.outward) or "relates to")
			append_issue(links, link.inwardIssue, json.safe_str(relationship.inward) or "relates to")
		end

		for _, remote in ipairs(json.safe_table(results.remote)) do
			local object = json.safe_table(remote.object)
			local url = json.safe_str(object.url)
			if url and url:match("^https?://") then
				local target = require("atlas.providers").resolve(url)
				local link_key = url
				if target and target.entity ~= "repo" then
					local marker = target.provider == "gitlab" and target.entity == "pr" and "!" or "#"
					link_key = target.repo_full_name
							and string.format("%s%s%s", target.repo_full_name, marker, target.id)
						or tostring(target.id)
				end
				table.insert(links, {
					url = url,
					key = link_key,
					title = json.safe_str(object.title),
					relationship = json.safe_str(remote.relationship) or "linked",
				})
			end
		end

		vim.list_extend(links, results.development or {})

		local messages = {}
		for _, source in ipairs({ "issues", "remote", "development" }) do
			if errors[source] then
				table.insert(messages, source .. ": " .. errors[source])
			end
		end
		if #messages == 0 then
			service.set_cache(cache_key, links)
		end
		local available = next(results) ~= nil
		on_done(available and links or nil, #messages > 0 and table.concat(messages, "; ") or nil)
	end)
	return requests
end

return M
