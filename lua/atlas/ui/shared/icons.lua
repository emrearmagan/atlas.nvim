local M = {}

local config = require("atlas.config")
local providers = require("atlas.providers")

---@class AtlasIconStyle
---@field icon string
---@field hl_group string

---@type table
local ICONS = {
	fallback = { icon = "", hl_group = "AtlasTextMuted" },

	general = {
		search = { icon = "", hl_group = "AtlasTextMuted" },
		folder_closed = { icon = "", hl_group = "AtlasLogInfo" },
		folder_open = { icon = "", hl_group = "AtlasLogInfo" },
		overview = { icon = "", hl_group = "AtlasTextMuted" },
		comment = { icon = "", hl_group = "AtlasTextMuted" },
		conversation = { icon = "", hl_group = "AtlasTextMuted" },
		created = { icon = "󰃭", hl_group = "AtlasTextMuted" },
		updated = { icon = "󰥔", hl_group = "AtlasTextMuted" },
		user = { icon = "", hl_group = "AtlasTextMuted" },
		reply = { icon = "", hl_group = "AtlasLogInfo" },
		edit = { icon = "", hl_group = "AtlasLogInfo" },
		delete = { icon = "󰆴", hl_group = "AtlasLogError" },
		progress = { icon = "󰦖", hl_group = "AtlasTextMuted" },
		success = { icon = "", hl_group = "AtlasTextPositive" },
		warning = { icon = "", hl_group = "AtlasLogWarn" },
		error = { icon = "", hl_group = "AtlasLogError" },
		info = { icon = "", hl_group = "AtlasLogInfo" },
		bell = { icon = "󰂚", hl_group = "AtlasTextMuted" },
		bell_no = { icon = "󰂛", hl_group = "AtlasTextMuted" },
		bell_unread = { icon = "󱅫", hl_group = "AtlasLogInfo" },
		pin = { icon = "󰐃", hl_group = "AtlasTextNote" },
		dot = { icon = "●", hl_group = "AtlasTextMuted" },
		activity_more = { icon = "󰉺", hl_group = "AtlasTextMuted" },
		star = { icon = "󰓎", hl_group = "AtlasTextWarning" },
		watching = { icon = "", hl_group = "AtlasTextPositive" },
		tasks = { icon = "󰘽", hl_group = "AtlasTextWarning" },
		arrow_up = { icon = "", hl_group = "AtlasTextMuted" },
		arrow_right = { icon = "", hl_group = "AtlasTextMuted" },
		fold_open = { icon = "", hl_group = "AtlasTextMuted" },
		fold_closed = { icon = "", hl_group = "AtlasTextMuted" },
		tag = { icon = "", hl_group = "AtlasTextWarning" },
	},

	pulls = {
		fork = { icon = "", hl_group = "AtlasLogInfo" },
		repo = { icon = "", hl_group = "AtlasTextMuted" },
		pr = { icon = "", hl_group = "AtlasTextPositive" },
		merged_pr = { icon = "", hl_group = "AtlasPRMerged" },
		declined_pr = { icon = "", hl_group = "AtlasPRDeclined" },
		pipeline = { icon = "󰜎", hl_group = "AtlasTextWarning" },
		commit = { icon = "", hl_group = "AtlasTextMuted" },
		changes = { icon = "󱓉", hl_group = "AtlasTextMuted" },
		file = { icon = "", hl_group = "AtlasTextMuted" },
		activity = { icon = "󱐋", hl_group = "AtlasTextMuted" },
		branch = { icon = "", hl_group = "AtlasLogInfo" },
		review = { icon = "", hl_group = "AtlasTextMuted" },

		status = {
			successful = { icon = "", hl_group = "AtlasTextPositive" },
			failed = { icon = "", hl_group = "AtlasLogError" },
			inprogress = { icon = "󰦖", hl_group = "AtlasTextWarning" },
			stopped = { icon = "󰓛", hl_group = "AtlasTextMuted" },
			unknown = { icon = "", hl_group = "AtlasTextMuted" },
		},
	},

	issues = {
		issue = { icon = "", hl_group = "AtlasTextPositive" },
		type = {
			epic = { icon = "", hl_group = "AtlasJiraEpic" },
			story = { icon = "󰃀", hl_group = "AtlasTextPositive" },
			task = { icon = "", hl_group = "AtlasLogInfo" },
			bug = { icon = "", hl_group = "AtlasLogError" },
			subtask = { icon = "󰩊", hl_group = "AtlasLogInfo" },
		},

		priority = {
			highest = { icon = "", hl_group = "AtlasLogError" },
			blocker = { icon = "", hl_group = "AtlasLogError" },
			high = { icon = "", hl_group = "AtlasLogError" },
			medium = { icon = "", hl_group = "AtlasTextWarning" },
			low = { icon = "", hl_group = "AtlasTextPositive" },
			lowest = { icon = "", hl_group = "AtlasTextPositive" },
		},
	},
}

ICONS.picker = {
	prompt = { icon = "›", hl_group = "AtlasTextNote" },
	selected = ICONS.general.success,
	unselected = { icon = "○", hl_group = "AtlasTextMuted" },
}

ICONS.actions = {
	success = ICONS.general.success,
	changes = ICONS.pulls.changes,
	merge = ICONS.pulls.merged_pr,
	edit = ICONS.general.edit,
	close = ICONS.general.error,
	reopen = { icon = "", hl_group = "AtlasTextPositive" },
	review = ICONS.pulls.review,
	user = ICONS.general.user,
	label = ICONS.pulls.tag,
	create = ICONS.issues.issue,
	search = ICONS.general.search,
	notification = ICONS.general.bell,
	pipeline = ICONS.pulls.pipeline,
	checkout = ICONS.pulls.branch,
	open_in_browser = { icon = "󰖟", hl_group = "AtlasTextMuted" },
	transition = ICONS.general.progress,
	delete = ICONS.general.delete,
	run = { icon = "", hl_group = "AtlasTextPositive" },
	stop = ICONS.pulls.status.stopped,
	retry = { icon = "󰑐", hl_group = "AtlasLogInfo" },
	details = ICONS.general.overview,
	save = { icon = "", hl_group = "AtlasTextMuted" },
	custom = { icon = "", hl_group = "AtlasTextMuted" },
}

---@param style AtlasIconStyle|nil
---@param fallback AtlasIconStyle|nil
---@return string, string
local function get(style, fallback)
	style = style or fallback or ICONS.fallback
	return style.icon, style.hl_group
end

-- Picker

---@param name string
---@return string, string
function M.picker(name)
	return get(ICONS.picker[name])
end

-- Actions

---@param name string
---@return string, string
function M.action(name)
	return get(ICONS.actions[name])
end

---@param action { label: string, icon?: string }
---@return string
function M.format_action(action)
	local icon = action.icon or M.action("custom")
	return icon .. "  " .. action.label
end

-- General

---@param name string
---@return string, string
function M.general(name)
	return get(ICONS.general[name])
end

-- Pulls

---@param name string
---@return string, string
function M.pulls(name)
	return get(ICONS.pulls[name], ICONS.general[name])
end

---@param status string
---@return string, string
function M.pulls_status(status)
	return get(ICONS.pulls.status[status])
end

-- Issues

---@param name string
---@return string, string
function M.issues(name)
	return get(ICONS.issues[name], ICONS.general[name])
end

---@param name string|nil
---@param provider_id AtlasIssuesProviderId|nil
---@return string, string
function M.issues_type(name, provider_id)
	local key = tostring(name or "")
	if provider_id == "shortcut" then
		key = key == "feature" and "story" or key == "chore" and "task" or key
		local style = ICONS.issues.type[key]
		if style then
			return get(style)
		end
		return "", "AtlasTextMuted"
	end

	local default = ICONS.issues.type[key:lower()]
	local jira = config.domain_options("jira", "issues") or {}
	local configured = ((jira.project_config or {}).issue_types or {})[key]

	if configured then
		return configured.icon or (default and default.icon) or "",
			configured.hl_group or (default and default.hl_group) or "AtlasTextMuted"
	end
	if default then
		return get(default)
	end
	local hl_group =
		require("atlas.ui.shared.highlights").dynamic_for(key ~= "" and ("jira-issue-type:" .. key:lower()) or nil)
	return "", hl_group or "AtlasTextMuted"
end

---@param name string|nil
---@return string, string
function M.issues_priority(name)
	local style = ICONS.issues.priority[tostring(name or ""):lower()]
	if style then
		return get(style)
	end
	return "", "AtlasTextMuted"
end

---@param provider_id AtlasIssuesProviderId
---@param name string
---@return string, string
function M.issues_provider(provider_id, name)
	local domain = providers.domain(provider_id, "issues")
	local style = nil
	if name == "provider" and domain then
		style = domain.icon
	end
	return get(style, ICONS.issues[name] or ICONS.pulls[name] or ICONS.general[name])
end

-- Fallback

---@return string, string
function M.fallback()
	return get(ICONS.fallback)
end

return M
