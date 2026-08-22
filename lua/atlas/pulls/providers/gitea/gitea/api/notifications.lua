local service = require("atlas.providers.gitea.gitea.client").pulls
local icons = require("atlas.ui.shared.icons")
local request_scope = require("atlas.core.requests")

local M = {}

local function normalize(raw)
	local subject = raw.subject
	local repository = raw.repository
	local subject_type = subject.type:lower()
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

	local repo = repository.full_name
	local state = subject.state or ""
	local subtitle = repo
	if state ~= "" then
		subtitle = subtitle ~= "" and (subtitle .. "  ·  " .. state) or state
	end
	local url = subject.html_url or subject.latest_comment_html_url or ""
	url = service.absolute_url(url) or ""
	return {
		id = tostring(raw.id),
		title = subject.title,
		subtitle = subtitle ~= "" and subtitle or nil,
		timestamp = raw.updated_at,
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
	local notifications = {}
	local requests = request_scope.new()
	local page_size = math.min(50, limit)
	local function fetch(page)
		local endpoint = "/notifications"
			.. service.query({
				all = false,
				["status-types"] = { "unread", "pinned" },
				page = page,
				limit = page_size,
			})
		requests.run(function(done)
			return service.request("GET", endpoint, nil, done)
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			for _, raw in ipairs(result) do
				local notification = normalize(raw)
				table.insert(notifications, notification)
				if #notifications == limit then
					break
				end
			end
			if #result > 0 and #notifications < limit then
				fetch(page + 1)
				return
			end
			on_done(notifications, nil)
		end)
	end
	fetch(1)
	return requests
end

local function mark_read(id, on_done)
	id = tostring(id or "")
	if id == "" then
		on_done(false, "Invalid Gitea notification ID")
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
