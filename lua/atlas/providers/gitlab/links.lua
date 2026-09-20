local M = {}

local service = require("atlas.providers.gitlab.client")
local json = require("atlas.core.json")
local config = require("atlas.config")

local WORK_ITEM_FIELDS = [[
fragment RelatedWorkItem on WorkItem {
  reference(full: true)
  title
  webUrl
  project { fullPath }
}
]]

local ISSUE_QUERY = [[
query($path: ID!, $iid: String!) {
  namespace(fullPath: $path) {
    workItem(iid: $iid) {
      widgets {
        ... on WorkItemWidgetHierarchy {
          parent { ...RelatedWorkItem }
          children(first: 100) { nodes { ...RelatedWorkItem } }
        }
        ... on WorkItemWidgetLinkedItems {
          linkedItems(first: 100) { nodes { linkType workItem { ...RelatedWorkItem } } }
        }
        ... on WorkItemWidgetDevelopment {
          closingMergeRequests(first: 100) {
            nodes { mergeRequest { reference(full: true) title webUrl } }
          }
          relatedMergeRequests(first: 100) {
            nodes { reference(full: true) title webUrl }
          }
        }
      }
    }
  }
}
]] .. WORK_ITEM_FIELDS

local PR_QUERY = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    mergeRequest(iid: $iid) {
      linkedWorkItems {
        linkType
        workItem { ...RelatedWorkItem }
        externalIssue { reference title webUrl }
      }
    }
  }
}
]] .. WORK_ITEM_FIELDS

local function nodes(connection)
	return json.safe_table(json.safe_table(connection).nodes)
end

local function issue_records(data)
	local item = json.nilify(json.safe_table(json.safe_table(data).namespace).workItem)
	if not item then
		return nil, "GitLab issue was not found"
	end
	local closing, referenced, linked, hierarchy = {}, {}, {}, {}
	for _, widget in ipairs(json.safe_table(item.widgets)) do
		for _, node in ipairs(nodes(widget.closingMergeRequests)) do
			table.insert(closing, { raw = node.mergeRequest, kind = "pr", relationship = "closed by" })
		end
		for _, raw in ipairs(nodes(widget.relatedMergeRequests)) do
			table.insert(referenced, { raw = raw, kind = "pr", relationship = "referenced by" })
		end
		for _, node in ipairs(nodes(widget.linkedItems)) do
			table.insert(linked, { raw = node.workItem, link_type = node.linkType, work_item = true })
		end
		local parent = json.nilify(widget.parent)
		if parent then
			table.insert(hierarchy, { raw = parent, relationship = "parent", work_item = true })
		end
		for _, child in ipairs(nodes(widget.children)) do
			table.insert(hierarchy, { raw = child, relationship = "sub-issue", work_item = true })
		end
	end
	vim.list_extend(closing, referenced)
	vim.list_extend(closing, linked)
	vim.list_extend(closing, hierarchy)
	return closing
end

local function pr_records(data)
	local pr = json.nilify(json.safe_table(json.safe_table(data).project).mergeRequest)
	if not pr then
		return nil, "GitLab merge request was not found"
	end
	local records = {}
	for _, node in ipairs(json.safe_table(pr.linkedWorkItems)) do
		local work_item = json.nilify(node.workItem)
		table.insert(records, {
			raw = work_item or json.nilify(node.externalIssue),
			work_item = work_item ~= nil,
			relationship = node.linkType == "CLOSES" and "closes" or "relates to",
		})
	end
	return records
end

local function to_link(record)
	local raw = json.safe_table(record.raw)
	local url = json.safe_str(raw.webUrl)
	local key = json.safe_str(raw.reference)
	local kind = record.kind or "issue"
	if record.work_item and json.nilify(raw.project) == nil then
		-- Group epics cannot be opened by the project issue provider.
		kind = "external"
	end
	if not url and key and key:match("^[A-Z][A-Z0-9_]*%-%d+$") then
		local jira = config.provider_options("jira") or {}
		if jira.base_url and jira.base_url ~= "" then
			url = jira.base_url:gsub("/+$", "") .. "/browse/" .. key
		end
	end
	if not url or url == "" then
		return nil
	end
	local relationships = {
		relates_to = "relates to",
		blocks = "blocks",
		is_blocked_by = "blocked by",
		blocked_by = "blocked by",
	}
	local link_type = json.safe_str(record.link_type)
	return {
		kind = kind,
		url = url,
		key = key or url,
		title = json.safe_str(raw.title) or "",
		relationship = relationships[link_type] or record.relationship or link_type,
	}
end

local function collect(path, iid, entity, opts, on_done)
	local cache_key = string.format("gitlab:links:%s:%s:%s:%d", service.base_url(), entity, path, iid)
	if not (opts and opts.force_refresh) then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	local query = entity == "issues" and ISSUE_QUERY or PR_QUERY
	return service.graphql(query, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end
		local parse = entity == "issues" and issue_records or pr_records
		local records, parse_err = parse(data)
		if not records then
			on_done(nil, parse_err)
			return
		end
		local links, seen, candidates, closing = {}, {}, {}, {}
		for _, record in ipairs(records) do
			local link = to_link(record)
			if link then
				table.insert(candidates, link)
				if link.relationship == "closes" or link.relationship == "closed by" then
					closing[link.url] = link.relationship
				end
			end
		end
		for _, link in ipairs(candidates) do
			local identity = link.url .. "\0" .. tostring(link.relationship)
			local redundant = (link.relationship == "relates to" and closing[link.url] == "closes")
				or (link.relationship == "referenced by" and closing[link.url] == "closed by")
			if not seen[identity] and not redundant then
				seen[identity] = true
				table.insert(links, link)
			end
		end
		service.set_memory_cache(cache_key, links)
		on_done(links, nil)
	end, { action = "Fetch GitLab relationships", path = path, iid = iid })
end

---@param issue IssueRef
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
function M.fetch_issue(issue, opts, on_done)
	local path, iid = tostring(issue.key or ""):match("^(.-)#(%d+)$")
	if not path or path == "" then
		on_done(nil, "Invalid GitLab issue key")
		return nil
	end
	return collect(path, tonumber(iid), "issues", opts, on_done)
end

---@param pr PullRequestRef
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
function M.fetch_pullrequest(pr, opts, on_done)
	local path, iid = tostring(pr.repo_full_name or ""), tonumber(pr.id)
	if path == "" or not iid then
		on_done(nil, "Invalid GitLab merge request identifier")
		return nil
	end
	return collect(path, iid, "merge_requests", opts, on_done)
end

return M
