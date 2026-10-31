local M = {}

local providers = require("atlas.providers")

---@class AtlasIconStyle
---@field icon string
---@field hl_group string|nil

---@type table<string, AtlasIconStyle>
local ICONS = {
	fallback = { icon = "", hl_group = "AtlasTextMuted" },

	overview = { icon = "", hl_group = "AtlasTextMuted" },
	search = { icon = "", hl_group = "AtlasTextMuted" },
	link = { icon = "", hl_group = "AtlasTextMuted" },

	folder_closed = { icon = "", hl_group = "AtlasLogInfo" },
	folder_open = { icon = "", hl_group = "AtlasLogInfo" },
	file = { icon = "", hl_group = "AtlasTextMuted" },
	fold_closed = { icon = "", hl_group = "AtlasTextMuted" },
	fold_open = { icon = "", hl_group = "AtlasTextMuted" },
	arrow_right = { icon = "", hl_group = "AtlasTextMuted" },

	repo = { icon = "", hl_group = "AtlasTextMuted" },
	branch = { icon = "", hl_group = "AtlasTextMuted" },
	fork = { icon = "", hl_group = "AtlasLogInfo" },
	commit = { icon = "", hl_group = "AtlasTextMuted" },
	tag = { icon = "", hl_group = "AtlasTextMuted" },
	changes = { icon = "󱓉", hl_group = "AtlasTextMuted" },
	pipeline = { icon = "󰜎", hl_group = "AtlasTextMuted" },

	pr = { icon = "", hl_group = "AtlasTextPositive" },
	draft_pr = { icon = "", hl_group = "AtlasPRDraft" },
	merged_pr = { icon = "", hl_group = "AtlasPRMerged" },
	declined_pr = { icon = "", hl_group = "AtlasPRDeclined" },
	stack = { icon = "󰌨", hl_group = "AtlasTextMuted" },
	lsp = { icon = "", hl_group = "AtlasTextMuted" },
	issue = { icon = "", hl_group = "AtlasTextPositive" },
	tasks = { icon = "󰘽", hl_group = "AtlasTextWarning" },

	user = { icon = "", hl_group = "AtlasTextMuted" },
	comment = { icon = "", hl_group = "AtlasTextMuted" },
	upvote = { icon = "", hl_group = "AtlasTextMuted" },
	conversation = { icon = "", hl_group = "AtlasTextMuted" },
	review = { icon = "", hl_group = "AtlasTextMuted" },

	activity = { icon = "󱐋", hl_group = "AtlasTextMuted" },
	activity_more = { icon = "󰉺", hl_group = "AtlasTextMuted" },
	created = { icon = "󰃭", hl_group = "AtlasTextMuted" },
	updated = { icon = "󰥔", hl_group = "AtlasTextMuted" },

	edit = { icon = "", hl_group = "AtlasTextMuted" },
	delete = { icon = "󰆴", hl_group = "AtlasLogError" },
	run = { icon = "", hl_group = "AtlasTextWarning" },
	stop = { icon = "󰓛", hl_group = "AtlasTextMuted" },

	pending = { icon = "○", hl_group = "AtlasTextMuted" },
	progress = { icon = "󰦖", hl_group = "AtlasTextWarning" },
	success = { icon = "", hl_group = "AtlasTextPositive" },
	check_circle = { icon = "", hl_group = "AtlasTextPositive" },
	info = { icon = "", hl_group = "AtlasTextMuted" },
	warning = { icon = "", hl_group = "AtlasTextMuted" },
	error = { icon = "", hl_group = "AtlasLogError" },

	checkbox_unchecked = { icon = "", hl_group = "AtlasTextMuted" },
	checkbox_checked = { icon = "", hl_group = "AtlasTextPositive" },

	bell = { icon = "󰂚", hl_group = "AtlasTextMuted" },
	bell_no = { icon = "󰂛", hl_group = "AtlasTextMuted" },
	bell_unread = { icon = "󱅫", hl_group = "AtlasLogInfo" },
	watching = { icon = "", hl_group = "AtlasTextPositive" },

	pin = { icon = "󰐃", hl_group = "AtlasTextNote" },
	star = { icon = "󰓎", hl_group = "AtlasTextWarning" },
	dot = { icon = "●", hl_group = "AtlasTextMuted" },
}

---@type table<string, table<string, AtlasIconStyle>>
local SECTIONS = {
	priority = {
		highest = { icon = "", hl_group = "AtlasLogError" },
		blocker = { icon = "", hl_group = "AtlasLogError" },
		high = { icon = "", hl_group = "AtlasLogError" },
		medium = { icon = "", hl_group = "AtlasTextWarning" },
		low = { icon = "", hl_group = "AtlasTextPositive" },
		lowest = { icon = "", hl_group = "AtlasTextPositive" },
	},
	status = {
		successful = ICONS.success,
		failed = ICONS.error,
		inprogress = ICONS.progress,
		pending = ICONS.pending,
		queued = ICONS.updated,
		paused = { icon = "", hl_group = "AtlasTextWarning" },
		canceled = ICONS.stop,
		skipped = ICONS.arrow_right,
		manual = ICONS.run,
		stopped = ICONS.stop,
	},
	log = {
		error = ICONS.error,
		warn = ICONS.warning,
		info = ICONS.info,
		debug = ICONS.info,
		success = ICONS.success,
		canceled = ICONS.stop,
		skipped = ICONS.arrow_right,
	},
	picker = {
		prompt = { icon = "›", hl_group = "AtlasTextNote" },
		selected = ICONS.success,
		unselected = ICONS.pending,
	},
	actions = {
		success = ICONS.success,
		changes = ICONS.changes,
		merge = ICONS.merged_pr,
		edit = ICONS.edit,
		close = ICONS.error,
		reopen = { icon = "", hl_group = "AtlasTextMuted" },
		review = ICONS.review,
		user = ICONS.user,
		label = ICONS.tag,
		create = ICONS.issue,
		search = ICONS.search,
		notification = ICONS.bell,
		pipeline = ICONS.pipeline,
		checkout = ICONS.branch,
		open_in_browser = { icon = "󰖟", hl_group = "AtlasTextMuted" },
		transition = { icon = "", hl_group = "AtlasTextMuted" },
		delete = ICONS.delete,
		run = ICONS.run,
		stop = ICONS.stop,
		retry = { icon = "󰑐", hl_group = "AtlasTextMuted" },
		details = ICONS.overview,
		save = { icon = "", hl_group = "AtlasTextMuted" },
		custom = { icon = "", hl_group = "AtlasTextMuted" },
	},
}

---@param name string
---@param section? "priority"|"status"|"log"|"picker"|"actions"
---@return string, string
function M.get(name, section)
	local style = (section and SECTIONS[section] or ICONS)[name:lower()] or ICONS.fallback
	return style.icon, style.hl_group
end

---@param provider_id AtlasProviderId
---@param domain AtlasDomain
---@return string, string
function M.provider_icon(provider_id, domain)
	local provider_domain = providers.domain(provider_id, domain)
	local style = provider_domain and provider_domain.icon or ICONS.fallback
	return style.icon, style.hl_group
end

return M
