local service = require("atlas.providers.forgejo.client").pulls
local pagination = require("atlas.pulls.providers.forgejo.api.pagination")
local json = require("atlas.core.json")

local M = {}

---@param pr PullRequest
---@return string|nil
local function cache_key(pr)
	local source = pr.source
	local head = source.commit_hash
	if head == "" then
		return nil
	end
	return table.concat({
		"forgejo:pulls:commits",
		service.url_encode(service.base_url()),
		service.url_encode(pr.repo_full_name),
		tostring(pr.id),
		service.url_encode(head),
	}, ":")
end

---@param pr PullRequest
---@return string|nil owner, string|nil repo, string|nil id
local function pull_parts(pr)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	local id = tostring(pr.id)
	if owner and id:match("^%d+$") then
		return owner, repo, id
	end
end

function M.fetch(pr, opts, on_done)
	local owner, repo, id = pull_parts(pr)
	if not owner then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	opts = opts or {}
	local key = cache_key(pr)
	if key and opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	local endpoint =
		string.format("/repos/%s/%s/pulls/%s/commits", service.url_encode(owner), service.url_encode(repo), id)
	return pagination.fetch_all(endpoint, nil, {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = {}
		for _, value in ipairs(raw) do
			local commit = value.commit
			local author = commit.author
			local account = json.nilify(value.author)
			local hash = value.sha
			local login = account and account.login or ""
			table.insert(commits, {
				hash = hash,
				short_hash = hash:sub(1, 7),
				message = commit.message or "",
				author_name = author.name or (account and (account.full_name or account.login)) or "",
				author_nickname = login ~= "" and login or nil,
				date = author.date or value.created or "",
				html_url = value.html_url,
				statuses_url = string.format(
					"/repos/%s/%s/statuses/%s",
					service.url_encode(owner),
					service.url_encode(repo),
					service.url_encode(hash)
				),
			})
		end
		if key then
			service.set_memory_cache(key, commits)
		end
		on_done(commits, nil)
	end)
end

return M
