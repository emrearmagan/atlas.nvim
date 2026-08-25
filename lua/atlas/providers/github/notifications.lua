local M = {}

local client = require("atlas.providers.github.client")
local icons = require("atlas.ui.shared.icons")

local pull_icon, pull_icon_hl = icons.pulls("pr")
local checks_icon, checks_icon_hl = icons.pulls("tasks")
local SUBJECT_ICON = {
	PullRequest = { icon = pull_icon, hl = pull_icon_hl },
	Issue = { icon = icons.issues("issue"), hl = "AtlasPROpen" },
	CheckSuite = { icon = checks_icon, hl = checks_icon_hl },
}

local FALLBACK_ICON = { icon = icons.general("info"), hl = "AtlasTextMuted" }

---@param reason string
---@return string
local function pretty_reason(reason)
	if reason == nil or reason == "" then
		return ""
	end
	return (reason:gsub("_", " "))
end

---@param raw table
---@return AtlasNotification
local function normalize(raw)
	local subject = raw.subject or {}
	local repo = tostring((raw.repository or {}).full_name or "")
	local subject_type = tostring(subject.type or "")
	local subject_url = subject.url and tostring(subject.url) or nil
	local raw_title = tostring(subject.title or "")

	local html_url = nil
	if subject_url and repo ~= "" then
		local number = subject_url:match("/(%d+)$")
		if number then
			if subject_type == "PullRequest" then
				html_url = string.format("https://github.com/%s/pull/%s", repo, number)
			elseif subject_type == "Issue" then
				html_url = string.format("https://github.com/%s/issues/%s", repo, number)
			end
		end
	end

	local icon_def = SUBJECT_ICON[subject_type] or FALLBACK_ICON

	local subtitle_parts = {}
	if repo ~= "" then
		table.insert(subtitle_parts, repo)
	end
	local reason = pretty_reason(tostring(raw.reason or ""))
	if reason ~= "" then
		table.insert(subtitle_parts, reason)
	end

	local updated_at = tostring(raw.updated_at or "")

	return {
		id = tostring(raw.id or ""),
		title = raw_title,
		subtitle = table.concat(subtitle_parts, "  "),
		timestamp = updated_at ~= "" and updated_at or nil,
		icon = icon_def.icon,
		icon_hl = icon_def.hl,
		unread = raw.unread == true,
		url = html_url,
	}
end

---@param opts { all: boolean|nil, per_page: number|nil, force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(opts, on_done)
	opts = vim.tbl_extend("force", { all = true, per_page = 100 }, opts or {})
	local per_page = tonumber(opts.per_page) or 100
	local all = opts.all == true

	local cache_key = string.format("github:notifications:all=%s:per_page=%d", tostring(all), per_page)

	if not opts.force_load then
		local cached, ok = client.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("notifications?per_page=%d", per_page)
	if all then
		endpoint = endpoint .. "&all=true"
	end

	return client.gh({ "api", endpoint }, function(result, err)
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

		client.set_mem(cache_key, notifications, 60)
		on_done(notifications, nil)
	end, {
		action = "Fetch notifications",
		all = all,
		limit = per_page,
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
		on_done(true, nil)
	end, {
		action = "Mark notification done",
		thread_id = thread_id,
	})
end

return M
