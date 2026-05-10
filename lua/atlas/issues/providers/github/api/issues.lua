local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

local SEARCH_JSON_FIELDS = "number,title,state,repository,author,assignees,labels,createdAt,updatedAt,closedAt,url,body,commentsCount"
local DETAIL_JSON_FIELDS = "number,title,state,author,assignees,labels,createdAt,updatedAt,closedAt,url,body,comments,milestone,reactionGroups"

---@param search string
---@param on_done fun(issues: Issue[]|nil, err: string|nil)
---@param opts { force_load?: boolean, limit?: number }|nil
---@return { cancel: fun() }|nil
function M.search_issues(search, on_done, opts)
	opts = opts or {}
	local limit = math.max(1, tonumber(opts.limit) or 50)

	local query = vim.trim(tostring(search or ""))
	if query == "" then
		on_done({}, "Missing search query")
		return nil
	end
	-- gh search issues also returns PRs by default; force-exclude them.
	-- The literal "is:issue" search operator is also stripped because GitHub's
	-- search API rejects it in some contexts.
	query = query:gsub("%s*is:issue%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")

	local cache_key = string.format("github_issues:search:%s:%d", query, limit)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	-- gh search issues silently quotes a multi-token query passed as one positional
	-- arg (e.g. `assignee:@me is:open` becomes `assignee:"@me is:open"`). Split on
	-- whitespace, but keep "quoted phrases" (with embedded quotes preserved verbatim
	-- so e.g. `label:"good first issue"` becomes a single token).
	local args = { "search", "issues" }
	do
		local i = 1
		while i <= #query do
			local c = query:sub(i, i)
			if c:match("%s") then
				i = i + 1
			else
				local token = {}
				local in_quote = false
				while i <= #query do
					local cc = query:sub(i, i)
					if cc == '"' then
						in_quote = not in_quote
						table.insert(token, cc)
						i = i + 1
					elseif cc:match("%s") and not in_quote then
						break
					else
						table.insert(token, cc)
						i = i + 1
					end
				end
				table.insert(args, table.concat(token))
			end
		end
	end
	table.insert(args, "--include-prs=false")
	table.insert(args, "--limit")
	table.insert(args, tostring(limit))
	table.insert(args, "--json")
	table.insert(args, SEARCH_JSON_FIELDS)

	logger.loginfo("GitHub issues search", { query = query, limit = limit, args = args })
	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local list = type(result) == "table" and result or {}
		local issues = normalizer.normalize_issues(list, nil)
		cli.set_cache(cache_key, issues)
		on_done(issues, nil)
	end)
end

---@param key string
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.get_issue(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local cache_key = string.format("github_issues:get:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch issue", { slug = slug, number = number })
	return cli.gh({
		"issue",
		"view",
		tostring(number),
		"--repo",
		slug,
		"--json",
		DETAIL_JSON_FIELDS,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local issue = normalizer.normalize_issue(result, slug)
		if issue then
			cli.set_cache(cache_key, issue)
		end
		on_done(issue, nil)
	end)
end

---@param key string
---@param state "open"|"closed"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local sub = state == "closed" and "close" or "reopen"
	logger.loginfo("GitHub issue state change", { slug = slug, number = number, state = state })
	return cli.gh({ "issue", sub, tostring(number), "--repo", slug }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param add_flag string
---@param remove_flag string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_issue_diff(key, diff, add_flag, remove_flag, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local adds = type(diff) == "table" and diff.add or {}
	local removes = type(diff) == "table" and diff.remove or {}
	if #adds == 0 and #removes == 0 then
		on_done(true, nil)
		return nil
	end

	local args = { "issue", "edit", tostring(number), "--repo", slug }
	for _, v in ipairs(adds) do
		table.insert(args, add_flag)
		table.insert(args, tostring(v))
	end
	for _, v in ipairs(removes) do
		table.insert(args, remove_flag)
		table.insert(args, tostring(v))
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_assignees(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-assignee", "--remove-assignee", on_done)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-label", "--remove-label", on_done)
end

---@param slug string
---@param on_done fun(labels: { name: string, color: string|nil, description: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	-- Re-export from pulls/github to keep one source of truth.
	local pulls_issues = require("atlas.pulls.providers.github.api.issues")
	return pulls_issues.list_labels(slug, on_done)
end

---@param slug string
---@param on_done fun(assignees: { login: string, name: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_assignees(slug, on_done)
	local pulls_issues = require("atlas.pulls.providers.github.api.issues")
	return pulls_issues.list_assignees(slug, on_done)
end

return M
