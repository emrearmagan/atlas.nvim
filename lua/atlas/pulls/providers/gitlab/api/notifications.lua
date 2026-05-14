local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local icons = require("atlas.ui.shared.icons")

local TARGET_ICON = {
	MergeRequest = { icon = icons.pulls("pr"), hl = "AtlasPROpen" },
	Issue = { icon = icons.issues("issue"), hl = "AtlasPROpen" },
}
local FALLBACK_ICON = { icon = icons.general("info"), hl = "AtlasTextMuted" }

---@param action string|nil
---@return string
local function pretty_action(action)
	local s = tostring(action or "")
	if s == "" then
		return ""
	end
	return (s:gsub("_", " "))
end

---@param raw table
---@return AtlasNotification
local function normalize(raw)
	local target_type = tostring(raw.target_type or "")
	local target = type(raw.target) == "table" and raw.target or {}
	local project = type(raw.project) == "table" and raw.project or {}
	local repo = tostring(project.path_with_namespace or project.name_with_namespace or "")

	local subtitle_parts = {}
	if repo ~= "" then
		table.insert(subtitle_parts, repo)
	end
	local action = pretty_action(raw.action_name)
	if action ~= "" then
		table.insert(subtitle_parts, action)
	end

	local icon_def = TARGET_ICON[target_type] or FALLBACK_ICON

	return {
		id = tostring(raw.id or ""),
		title = tostring(target.title or raw.body or ""),
		subtitle = table.concat(subtitle_parts, "  ·  "),
		timestamp = tostring(raw.updated_at or raw.created_at or ""),
		icon = icon_def.icon,
		icon_hl = icon_def.hl,
		unread = tostring(raw.state or "") == "pending",
		url = type(raw.target_url) == "string" and raw.target_url or nil,
		_raw = raw,
	}
end

---@param opts { state: "pending"|"done"|"all"|nil, per_page: number|nil, force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(opts, on_done)
	opts = opts or {}
	local per_page = math.max(1, math.min(100, tonumber(opts.per_page) or 50))
	local state = opts.state or "pending"

	local cache_key = string.format("gitlab:todos:state=%s:per_page=%d", state, per_page)
	if not opts.force_load then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/todos?per_page=%d", per_page)
	if state ~= "all" then
		endpoint = endpoint .. "&state=" .. state
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local notifications = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			table.insert(notifications, normalize(raw))
		end
		service.set_cache(cache_key, notifications, 60)
		on_done(notifications, nil)
	end)
end

---GitLab has no separate "read" state like githubb treat read the same as done.
---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_read(id, on_done)
	return M.mark_done(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_done(id, on_done)
	local endpoint = string.format("/todos/%s/mark_as_done", tostring(id))
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

return M
