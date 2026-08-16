local service = require("atlas.providers.gitea.gitea.client").pulls
local pagination = require("atlas.pulls.providers.gitea.gitea.api.pagination")
local json = require("atlas.core.json")

local M = {}

local function pull_parts(pr)
	if type(pr) ~= "table" then
		return nil
	end
	local owner, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	local id = tostring(pr.id or "")
	if owner and id:match("^%d+$") then
		return owner, repo, id
	end
end

function M.fetch(pr, _, on_done)
	local owner, repo, id = pull_parts(pr)
	if not owner then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	local endpoint =
		string.format("/repos/%s/%s/pulls/%s/commits", service.url_encode(owner), service.url_encode(repo), id)
	return pagination.fetch_all(endpoint, nil, {
		invalid_response = "Invalid pull request commits response",
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = {}
		for _, value in ipairs(raw or {}) do
			if type(value) ~= "table" or tostring(value.sha or "") == "" then
				on_done(nil, "Invalid pull request commits response")
				return
			end
			local commit = json.safe_table(value.commit)
			local author = json.safe_table(commit.author)
			local account = json.safe_table(value.author)
			local hash = value.sha
			local login = account.login or ""
			table.insert(commits, {
				hash = hash,
				short_hash = hash:sub(1, 7),
				message = commit.message or "",
				author_name = author.name or account.full_name or account.login or "",
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
		on_done(commits, nil)
	end)
end

return M
