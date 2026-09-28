local M = {}

local client = require("atlas.providers.github.client")
local json = require("atlas.core.json")

local FIELDS = "number title url repository { nameWithOwner }"
local SUBJECT = "__typename ... on Issue { " .. FIELDS .. " } ... on PullRequest { " .. FIELDS .. " }"

local ISSUE_CONNECTIONS = {
	{ name = "sub-issues", field = "subIssues", kind = "issue", relationship = "sub-issue" },
	{
		name = "linked pull requests",
		field = "closedByPullRequestsReferences",
		arguments = ", includeClosedPrs: true",
		kind = "pr",
		relationship = "closed by",
	},
	{ name = "blocking issues", field = "blockedBy", kind = "issue", relationship = "blocked by" },
	{ name = "blocked issues", field = "blocking", kind = "issue", relationship = "blocks" },
	{ name = "references", field = "timelineItems", timeline = true },
}

local PR_CONNECTIONS = {
	{ name = "closing issues", field = "closingIssuesReferences", kind = "issue", relationship = "closes" },
	{ name = "references", field = "timelineItems", timeline = true },
}

---@param raw any
---@param kind string|nil
---@param relationship AtlasRelationship
---@return AtlasRelatedItem|nil
local function to_link(raw, kind, relationship)
	raw = json.safe_table(raw)
	local url = json.safe_str(raw.url)
	local number = tonumber(raw.number)
	local slug = json.safe_str(json.safe_table(raw.repository).nameWithOwner)
	if not url or url == "" or not number or not slug or slug == "" then
		return nil
	end
	return {
		kind = kind or (raw.__typename == "PullRequest" and "pr" or "issue"),
		url = url,
		key = string.format("%s#%d", slug, number),
		title = json.safe_str(raw.title) or "",
		relationship = relationship,
	}
end

local function query_for(kind, connections)
	local fields = { "url" }
	if kind == "issue" then
		table.insert(fields, "parent { " .. FIELDS .. " }")
	end
	for _, connection in ipairs(connections) do
		local selection = FIELDS
		local arguments = connection.arguments or ""
		if connection.timeline then
			arguments = ", itemTypes: [CROSS_REFERENCED_EVENT]"
			selection = "... on CrossReferencedEvent { source { " .. SUBJECT .. " } target { " .. SUBJECT .. " } }"
		end
		table.insert(fields, string.format("%s(first: 100%s) { nodes { %s } }", connection.field, arguments, selection))
	end
	return string.format(
		[[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    item: %s(number: $number) {
      %s
    }
  }
}]],
		kind == "pr" and "pullRequest" or "issue",
		table.concat(fields, "\n      ")
	)
end

local function related_items(kind, item, connections)
	local links, messages, seen, closing = {}, {}, {}, {}
	local function add(raw, link_kind, relationship)
		local link = to_link(raw, link_kind, relationship)
		if not link then
			return
		end
		local identity = link.url .. "\0" .. relationship
		local reference = relationship == "references" or relationship == "referenced by"
		if seen[identity] or (reference and closing[link.url]) then
			return
		end
		seen[identity] = true
		if relationship == "closes" or relationship == "closed by" then
			closing[link.url] = true
		end
		table.insert(links, link)
	end
	if kind == "issue" then
		add(item.parent, "issue", "parent")
	end
	for _, connection in ipairs(connections) do
		local related = json.nilify(item[connection.field])
		if type(related) ~= "table" then
			table.insert(messages, connection.name .. ": relationship data is unavailable")
		end
		for _, node in ipairs(json.safe_table(json.safe_table(related).nodes)) do
			node = json.safe_table(node)
			if connection.timeline then
				local source = json.safe_table(node.source)
				local target = json.safe_table(node.target)
				if source.url == item.url then
					if target.url ~= item.url then
						add(target, nil, "references")
					end
				elseif source.url ~= item.url then
					add(source, nil, "referenced by")
				end
			else
				add(node, connection.kind, connection.relationship)
			end
		end
	end
	return links, messages
end

local function fetch(kind, entity, opts, done)
	opts = opts or {}
	local slug, number = entity.repo_full_name, kind == "pr" and entity.id or entity.number
	if kind == "issue" and entity.key then
		local key_slug, key_number = entity.key:match("^(.-)#(%d+)$")
		slug, number = key_slug or slug, key_number or number
	end
	local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
	number = tonumber(number)
	if not owner or not repo or not number or number < 1 or number % 1 ~= 0 then
		done(nil, "Missing or invalid GitHub issue/pull request reference")
		return nil
	end
	local cache_key = string.format("github:links:%s:%s:%d", kind, slug, number)
	if not opts.force_refresh then
		local cached, ok = client.get_mem(cache_key)
		if ok then
			done(cached, nil)
			return nil
		end
	end

	local connections = kind == "pr" and PR_CONNECTIONS or ISSUE_CONNECTIONS
	return client.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. query_for(kind, connections),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(number),
	}, function(result, err)
		if err then
			done(nil, err)
			return
		end
		local data = json.safe_table(json.safe_table(result).data)
		local item = json.nilify(json.safe_table(data.repository).item)
		if type(item) ~= "table" then
			done(nil, "Issue or pull request was not found")
			return
		end
		local links, messages = related_items(kind, item, connections)
		for _, error in ipairs(json.safe_table(json.safe_table(result).errors)) do
			table.insert(
				messages,
				json.safe_str(json.safe_table(error).message) or "GitHub relationship data is incomplete"
			)
		end
		if #messages == 0 then
			client.set_mem(cache_key, links)
		end
		done(links, #messages > 0 and table.concat(messages, "; ") or nil)
	end, { action = "Fetch GitHub links", repository = slug, number = number })
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
function M.fetch_issue(issue, opts, done)
	return fetch("issue", issue, opts, done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
function M.fetch_pr(pr, opts, done)
	return fetch("pr", pr, opts, done)
end

return M
