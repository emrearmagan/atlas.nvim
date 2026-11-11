-- https://learn.microsoft.com/en-us/azure/devops/boards/queries/link-type-reference?view=azure-devops

local M = {}

local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.azure.client")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local pulls_mapper = require("atlas.pulls.providers.azure.api.mapper")

---@type table<string, AtlasRelationship>
local relationships = {
	["System.LinkTypes.Hierarchy-Reverse"] = "parent",
	["System.LinkTypes.Hierarchy-Forward"] = "child",
	["System.LinkTypes.Related"] = "relates to",
}

---@param item Issue
---@param relationship AtlasRelationship
---@return AtlasRelatedItem
local function issue_link(item, relationship)
	return { kind = "issue", url = item.url, key = item.key, title = item.title, relationship = relationship }
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_issue(issue, opts, on_done)
	opts = opts or {}
	local cache_key = "links:issue:" .. issue.key
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = request_scope.new()
	scope.run(function(done)
		local query = service.build_query({ ["$expand"] = "relations" })
		return service.request("GET", "/_apis/wit/workitems/" .. service.url_encode(issue.key) .. query, nil, done, {
			action = "Fetch work item links",
			issue_key = issue.key,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local refs, relationship_by_key, pulls, hyperlinks = {}, {}, {}, {}
		for _, relation in ipairs(json.safe_table(result.relations)) do
			local attributes = json.safe_table(relation.attributes)
			local id = relation.url:match("/_apis/wit/[Ww]ork[Ii]tems/(%d+)$")
			local artifact = relation.url:match("^vstfs:///Git/PullRequestId/(.+)$")

			if id and not relation.rel:find(".Remote.", 1, true) then
				table.insert(refs, { key = id })
				relationship_by_key[id] = relationships[relation.rel]
					or (json.safe_str(attributes.name) or "linked"):lower()
			elseif artifact then
				local project_id, pull_id = artifact:gsub("%%2[Ff]", "/"):match("^([^/]+)/[^/]+/(%d+)$")
				if pull_id then
					table.insert(pulls, { project_id = project_id, id = pull_id })
				end
			elseif relation.rel == "Hyperlink" then
				table.insert(hyperlinks, {
					kind = "external",
					url = relation.url,
					key = relation.url,
					title = json.safe_str(attributes.comment),
					relationship = "linked",
				})
			end
		end

		local starts = {
			items = function(done)
				return issues_api.fetch_by_refs(refs, opts, done)
			end,
		}
		for index, pull in ipairs(pulls) do
			starts[index] = function(done)
				local endpoint = string.format("/%s/_apis/git/pullrequests/%s", pull.project_id, pull.id)
				return service.request("GET", endpoint, nil, done, {
					action = "Fetch linked pull request",
					id = pull.id,
				})
			end
		end

		scope.all(starts, function(values, errors)
			local _, fetch_err = next(errors)
			if fetch_err then
				on_done(nil, fetch_err)
				return
			end

			local links = {}
			for _, item in ipairs(values.items) do
				table.insert(links, issue_link(item, relationship_by_key[item.key]))
			end
			for index = 1, #pulls do
				local pr = pulls_mapper.to_pull_request(values[index])
				table.insert(links, {
					kind = "pr",
					url = pr.link.html,
					key = tostring(pr.id),
					title = pr.title,
					relationship = "development",
				})
			end
			vim.list_extend(links, hyperlinks)

			service.set_cache(cache_key, links)
			on_done(links, nil)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_pullrequest(pr, opts, on_done)
	---@cast pr AzurePullRequest
	opts = opts or {}
	local cache_key = "links:pr:" .. pr.repository_id .. ":" .. pr.id
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = request_scope.new()
	scope.run(function(done)
		local endpoint = string.format(
			"/%s/_apis/git/repositories/%s/pullRequests/%d/workitems",
			pr.project_id,
			pr.repository_id,
			pr.id
		)
		return service.request("GET", endpoint, nil, done, {
			action = "Fetch pull request work items",
			repo = pr.repo_full_name,
			id = pr.id,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local refs = {}
		for _, ref in ipairs(result.value) do
			table.insert(refs, { key = tostring(ref.id) })
		end

		scope.run(function(done)
			return issues_api.fetch_by_refs(refs, opts, done)
		end, function(items, items_err)
			if items_err then
				on_done(nil, items_err)
				return
			end

			local links = {}
			for _, item in ipairs(items) do
				table.insert(links, issue_link(item, "linked"))
			end

			service.set_cache(cache_key, links)
			on_done(links, nil)
		end)
	end)
	return scope
end

return M
