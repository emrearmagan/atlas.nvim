local service = require("atlas.providers.gitea.forgejo.client").pulls
local icons = require("atlas.ui.shared.icons")
local json = require("atlas.core.json")

local M = {}

local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if key ~= "__http_status" and type(key) ~= "number" then
			return false
		end
	end
	return true
end

local function normalize(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local subject = json.safe_table(json.nilify(raw.subject))
	local repository = json.safe_table(json.nilify(raw.repository))
	local subject_type = (json.safe_str(subject.type) or ""):lower()
	local icon, icon_hl
	if subject_type == "pull" or subject_type == "pullrequest" then
		icon, icon_hl = icons.pulls("pr")
	elseif subject_type == "issue" then
		icon, icon_hl = icons.issues("issue")
	elseif subject_type == "commit" then
		icon, icon_hl = icons.pulls("commit")
	elseif subject_type == "repository" then
		icon, icon_hl = icons.pulls("repo")
	else
		icon, icon_hl = icons.general("info")
	end

	local repo = json.safe_str(repository.full_name) or ""
	local state = json.safe_str(subject.state) or ""
	local subtitle = repo
	if state ~= "" then
		subtitle = subtitle ~= "" and (subtitle .. "  ·  " .. state) or state
	end
	local url = json.safe_str(subject.html_url) or json.safe_str(subject.latest_comment_html_url) or ""
	url = service.absolute_url(url) or ""
	return {
		id = tostring(raw.id),
		title = json.safe_str(subject.title) or "",
		subtitle = subtitle ~= "" and subtitle or nil,
		timestamp = json.safe_str(raw.updated_at),
		icon = icon,
		icon_hl = icon_hl,
		unread = raw.unread == true,
		url = url ~= "" and url or nil,
		_raw = raw,
	}
end

function M.fetch(opts, on_done)
	opts = opts or {}
	local limit = math.max(1, math.min(100, tonumber(opts.limit) or 100))
	local notifications, active, cancelled = {}, nil, false
	local page_size = math.min(50, limit)
	local function fetch(page)
		local endpoint = "/notifications"
			.. service.query({
				all = false,
				["status-types"] = { "unread", "pinned" },
				page = page,
				limit = page_size,
			})
		local advanced = false
		local handle = service.request("GET", endpoint, nil, function(result, err)
			if cancelled then
				return
			end
			if err or not is_list(result) then
				on_done(nil, err or "Invalid Forgejo notifications response")
				return
			end
			for _, raw in ipairs(result) do
				local notification = normalize(raw)
				if notification then
					table.insert(notifications, notification)
					if #notifications == limit then
						break
					end
				end
			end
			if #result > 0 and #notifications < limit then
				advanced = true
				fetch(page + 1)
				return
			end
			on_done(notifications, nil)
		end)
		if not advanced then
			active = handle
		end
	end
	fetch(1)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
end

local function mark_read(id, on_done)
	id = tostring(id or "")
	if id == "" then
		on_done(false, "Invalid Forgejo notification ID")
		return nil
	end
	local endpoint = "/notifications/threads/" .. service.url_encode(id) .. service.query({ ["to-status"] = "read" })
	return service.request("PATCH", endpoint, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

M.mark_read = mark_read
M.mark_done = mark_read
return M
