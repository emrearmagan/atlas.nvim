local M = {}

local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.jira.client")
local url_encode = require("atlas.core.utils").url_encode

---@param links AtlasRelatedItem[]
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
		kind = "issue",
		url = service.base_url():gsub("/+$", "") .. "/browse/" .. key,
		key = key,
		title = json.safe_str(fields.summary),
		relationship = relationship,
	})
end

---@param raw table
---@return AtlasRelatedItem[]
function M.issue_links(raw)
	local links = {}
	local fields = json.safe_table(raw.fields)
	append_issue(links, fields.parent, "parent")
	for _, subtask in ipairs(json.safe_table(fields.subtasks)) do
		append_issue(links, subtask, "sub-issue")
	end
	for _, link in ipairs(json.safe_table(fields.issuelinks)) do
		local relationship = json.safe_table(link.type)
		append_issue(links, link.outwardIssue, json.safe_str(relationship.outward) or "relates to")
		append_issue(links, link.inwardIssue, json.safe_str(relationship.inward) or "relates to")
	end
	return links
end

---@param raw table[]
---@return AtlasRelatedItem[]
function M.remote_links(raw)
	local links = {}
	for _, remote in ipairs(json.safe_table(raw)) do
		local object = json.safe_table(remote.object)
		local url = json.safe_str(object.url)
		if url and url:match("^https?://") then
			local target = require("atlas.providers").resolve(url)
			local kind = target and target.entity ~= "repo" and target.entity or "external"
			local key = url
			if target and kind ~= "external" then
				local marker = target.provider == "gitlab" and kind == "pr" and "!" or "#"
				key = target.issue_key
					or string.format("%s%s%s", target.repo_full_name or "", marker, target.number or target.id)
			end
			table.insert(links, {
				kind = kind,
				url = url,
				key = key,
				title = json.safe_str(object.title),
				relationship = json.safe_str(remote.relationship) or "linked",
			})
		end
	end
	return links
end

---@param issue_id string
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
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
						kind = "pr",
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

---@param issue JiraIssue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(issue, opts, on_done)
	local key = tostring(issue.key or "")
	if not key:match("^[A-Z][A-Z0-9_]*%-%d+$") then
		on_done(nil, "Invalid Jira issue key")
		return nil
	end
	local cache_key = "jira:links:" .. service.base_url() .. ":" .. key
	if not (opts or {}).force_refresh then
		local cached, found = service.get_memory_cache(cache_key)
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
		local links = results.issues and M.issue_links(results.issues) or {}
		vim.list_extend(links, results.remote and M.remote_links(results.remote) or {})
		vim.list_extend(links, results.development or {})
		local messages = {}
		for _, source in ipairs({ "issues", "remote", "development" }) do
			if errors[source] then
				table.insert(messages, source .. ": " .. errors[source])
			end
		end
		if #messages == 0 then
			service.set_memory_cache(cache_key, links)
		end
		local available = next(results) ~= nil
		on_done(available and links or nil, #messages > 0 and table.concat(messages, "; ") or nil)
	end)
	return requests
end

return M
