local M = {}

local diff = require("atlas.ui.components.diff_hunks")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pulls.diff.atlas.state")
local renderer = require("atlas.ui.statusline")

local EXPRESSION = "%!v:lua.require'atlas.pulls.diff.atlas.statusline'.current()"

---@param win integer
function M.attach(win)
	vim.api.nvim_set_option_value("statusline", EXPRESSION, { win = win, scope = "local" })
end

---@class AtlasNativeDiffStatuslineNotice: AtlasStatuslineNotice
---@field token integer

---@class AtlasNativeDiffStatusline
---@field items AtlasStatuslineSegment[]
---@field notice AtlasNativeDiffStatuslineNotice
---@field spinner SpinnerInstance|nil

---@return AtlasNativeDiffStatusline
function M.new()
	return {
		items = {},
		notice = { text = "", hl_group = "AtlasFooterText", token = 0 },
		spinner = nil,
	}
end

---@param current AtlasNativeDiffStatusline
local function stop_spinner(current)
	if current.spinner then
		current.spinner:stop()
		current.spinner = nil
	end
end

---@param session AtlasNativeDiffSession
---@return integer additions, integer deletions
local function total_stats(session)
	local additions, deletions = 0, 0
	for _, file in ipairs(session.files) do
		local file_additions, file_deletions = diff.file_stats(file)
		additions = additions + file_additions
		deletions = deletions + file_deletions
	end
	return additions, deletions
end

---@param session AtlasNativeDiffSession
---@return integer|nil comments, integer tasks, string task_label
local function review_counts(session)
	if not session.review or not session.review.pr then
		return nil, 0, "Task"
	end
	local tasks = session.review.tasks
	local task_label = tasks[1] and tasks[1].task_label or "Task"
	return #session.review.comments, #tasks, task_label
end

---@param session AtlasNativeDiffSession
---@return string
local function identity(session)
	local configured_review = session.review_context
	local pr = session.review and session.review.pr or (configured_review and configured_review.pr)
	if pr then
		return string.format("PR #%s · %s", tostring(pr.id), tostring(pr.title))
	end
	return string.format(
		"%s...%s",
		tostring(session.range.base_revision):sub(1, 8),
		tostring(session.range.head_revision):sub(1, 8)
	)
end

---@param session AtlasNativeDiffSession
---@return AtlasStatuslineSegment[]
local function segments(session)
	local additions, deletions = total_stats(session)
	local comments, tasks, task_label = review_counts(session)
	local result = {
		{ text = identity(session), hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
	}

	if comments then
		result[#result + 1] = {
			text = string.format("comments %d", comments),
			hl_group = "AtlasFooterText",
			align = "right",
			priority = 30,
		}
	end
	if tasks > 0 then
		result[#result + 1] = {
			text = string.format("%ss %d", task_label:lower(), tasks),
			hl_group = "AtlasFooterText",
			align = "right",
			priority = 20,
		}
	end
	if #session.commits > 0 then
		result[#result + 1] = {
			text = string.format("commits %d", #session.commits),
			hl_group = "AtlasFooterText",
			align = "right",
			priority = 10,
		}
	end
	result[#result + 1] = {
		text = string.format("+%d", additions),
		hl_group = "AtlasFooterSuccess",
		align = "right",
	}
	result[#result + 1] = {
		text = string.format("-%d", deletions),
		hl_group = "AtlasFooterError",
		align = "right",
	}
	return result
end

---@param session AtlasNativeDiffSession
function M.update(session)
	if not session.closing then
		session.statusline.items = segments(session)
		vim.cmd("redrawstatus")
	end
end

---@param level "loading"|"success"|"warn"|"error"|"info"
---@return string icon, string hl_group
local function notice_style(level)
	local icon_name = level == "warn" and "warning" or level
	local icon = level == "loading" and "" or icons.general(icon_name)
	local highlights = {
		loading = "AtlasFooterInfo",
		success = "AtlasFooterSuccess",
		warn = "AtlasFooterWarning",
		error = "AtlasFooterError",
		info = "AtlasFooterInfo",
	}
	return icon, highlights[level] or "AtlasFooterText"
end

---@param session AtlasNativeDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration? integer
function M.notify(session, level, message, duration)
	local current = session.statusline
	message = tostring(message or ""):gsub("[\r\n]+", " | ")
	message = #message > 60 and message:sub(1, 57) .. "..." or message
	current.notice.token = current.notice.token + 1
	local token = current.notice.token
	stop_spinner(current)

	local icon, hl_group = notice_style(level)
	current.notice.hl_group = hl_group
	if level == "loading" then
		current.spinner = spinner.create({
			on_tick = function(frame)
				if session.closing or current.notice.token ~= token then
					stop_spinner(current)
					return
				end
				current.notice.text = string.format("%s %s", frame, message)
				vim.cmd("redrawstatus")
			end,
		})
		current.notice.text = current.spinner:text(message)
		current.spinner:start()
		vim.cmd("redrawstatus")
		return
	end

	current.notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	vim.cmd("redrawstatus")
	vim.defer_fn(function()
		if session.closing or current.notice.token ~= token then
			return
		end
		current.notice.text = ""
		current.notice.hl_group = "AtlasFooterText"
		vim.cmd("redrawstatus")
	end, duration or 2500)
end

---@return string
function M.current()
	local session = state.get(vim.api.nvim_get_current_tabpage())
	if not session or session.closing then
		return ""
	end
	return renderer.format(session.statusline.items, session.statusline.notice)
end

---@param session AtlasNativeDiffSession
function M.dispose(session)
	stop_spinner(session.statusline)
end

return M
