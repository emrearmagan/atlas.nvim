local M = {}
---@cast M AtlasNotificationsCapability

local client = require("atlas.providers.github.client")

---@class GitHubNotification : AtlasNotification
---@field repo string
---@field subject_url string

local SUBJECT_KIND = {
	PullRequest = "pr",
	Issue = "issue",
	CheckSuite = "checks",
	Release = "release",
	Discussion = "discussion",
}

---@param subject_type string
---@param subject_url string|nil
---@param repo string
---@return string|nil
local function web_url(subject_type, subject_url, repo)
	if repo == "" then
		return nil
	end
	local base = string.format("https://%s/%s", client.hostname(), repo)
	local number = subject_url and subject_url:match("/(%d+)$")
	local sha = subject_url and subject_url:match("/commits/(%x+)$")
	if subject_type == "PullRequest" and number then
		return base .. "/pull/" .. number
	elseif subject_type == "Issue" and number then
		return base .. "/issues/" .. number
	elseif subject_type == "Discussion" and number then
		return base .. "/discussions/" .. number
	elseif subject_type == "Commit" and sha then
		return base .. "/commit/" .. sha
	elseif subject_type == "Release" then
		return base .. "/releases"
	elseif subject_type == "CheckSuite" then
		return base .. "/actions"
	elseif subject_type == "RepositoryVulnerabilityAlert" or subject_type == "RepositoryDependabotAlertsThread" then
		return base .. "/security/dependabot"
	elseif subject_type == "RepositoryInvitation" then
		return base .. "/invitations"
	end
	return base
end

---@param raw table
---@return GitHubNotification
local function normalize(raw)
	local subject = raw.subject or {}
	local repo = tostring((raw.repository or {}).full_name or "")
	local subject_type = tostring(subject.type or "")
	local subject_url = subject.url and tostring(subject.url) or nil
	local raw_title = tostring(subject.title or "")

	local subtitle_parts = {}
	if repo ~= "" then
		table.insert(subtitle_parts, repo)
	end
	local reason = tostring(raw.reason or ""):gsub("_", " ")
	if reason ~= "" then
		table.insert(subtitle_parts, reason)
	end

	local updated_at = tostring(raw.updated_at or "")

	return {
		id = tostring(raw.id or ""),
		title = raw_title,
		subtitle = table.concat(subtitle_parts, "  "),
		timestamp = updated_at ~= "" and updated_at or nil,
		kind = SUBJECT_KIND[subject_type],
		unread = raw.unread == true,
		url = web_url(subject_type, subject_url, repo),
		repo = repo,
		subject_url = subject_url or "",
	}
end

---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(opts, on_done)
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_mem("github:notifications")
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return client.gh({ "api", "notifications?per_page=100&all=true" }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			on_done({}, nil)
			return
		end

		local notifications = {}
		for _, raw in ipairs(result) do
			table.insert(notifications, normalize(raw))
		end

		client.set_mem("github:notifications", notifications, 60)
		on_done(notifications, nil)
	end, {
		action = "Fetch notifications",
	})
end

---@param thread_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_read(thread_id, on_done)
	return client.api("PATCH", "notifications/threads/" .. thread_id, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		client.delete_mem("github:notifications")
		on_done(true, nil)
	end, {
		action = "Mark notification read",
		thread_id = thread_id,
	})
end

---@param thread_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_done(thread_id, on_done)
	return client.api("DELETE", "notifications/threads/" .. thread_id, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		client.delete_mem("github:notifications")
		on_done(true, nil)
	end, {
		action = "Mark notification done",
		thread_id = thread_id,
	})
end

---@param notification AtlasNotification
---@return boolean
function M.open(notification)
	---@cast notification GitHubNotification
	if notification.kind == "checks" then
		local provider = require("atlas.providers").load("github", "pulls")
		---@cast provider PullsProvider
		local branch = notification.title:match(" for (%S+) branch$")
		if branch == nil then
			require("atlas.ui.repository").open(notification.repo, provider, { page = "builds" })
		else
			require("atlas.pulls.pipelines").open({
				provider = "github",
				repo_full_name = notification.repo,
				target = branch,
			}, provider)
		end
	elseif notification.kind == "release" then
		local provider = require("atlas.providers").load("github", "pulls")
		---@cast provider PullsProvider
		require("atlas.ui.repository").open(notification.repo, provider, {
			page = "releases",
			ctx = { release_id = notification.subject_url:match("/releases/(%d+)$") },
		})
	elseif notification.kind == "discussion" then
		local provider = require("atlas.providers").load("github", "pulls")
		---@cast provider PullsProvider
		require("atlas.ui.repository").open(notification.repo, provider, {
			page = "discussions",
			ctx = { number = tonumber(notification.subject_url:match("/discussions/(%d+)$")) },
		})
	elseif notification.kind == "pr" or notification.kind == "issue" then
		if notification.url == nil then
			return false
		end
		require("atlas.commands.open").open(notification.url)
	else
		return false
	end
	return true
end

return M
