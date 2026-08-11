local M = {}

local diff = require("atlas.ui.components.diff_hunks")
local keymaps = require("atlas.core.keymaps")
local state = require("atlas.pulls.diff.atlas.state")
local renderer = require("atlas.ui.statusline")
local summary = require("atlas.pulls.diff.shared.ui.statusline")

local EXPRESSION = "%!v:lua.require'atlas.pulls.diff.atlas.statusline'.current()"

---@param win integer
function M.attach(win)
	vim.api.nvim_set_option_value("statusline", EXPRESSION, { win = win, scope = "local" })
end

---@class AtlasNativeDiffStatusline: AtlasDiffStatuslineState
---@field items AtlasStatuslineSegment[]

---@return AtlasNativeDiffStatusline
function M.new()
	---@type AtlasNativeDiffStatusline
	local current = summary.new()
	current.items = {}
	return current
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
---@return string
local function identity(session)
	local configured_review = session.review_context
	local pr = session.review and session.review.pr or (configured_review and configured_review.pr)
	if pr then
		return string.format("#%s %s", tostring(pr.id), tostring(pr.title))
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
	return summary.items(identity(session), additions, deletions, session.review, session.notes)
end

---@param session AtlasNativeDiffSession
function M.update(session)
	if not session.closing then
		session.statusline.items = segments(session)
		vim.cmd("redrawstatus")
	end
end

---@param session AtlasNativeDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration? integer
function M.notify(session, level, message, duration)
	summary.notify(session.statusline, level, message, duration)
end

---@return string
function M.current()
	local session = state.get(vim.api.nvim_get_current_tabpage())
	if not session or session.closing then
		return ""
	end
	local help_keys = keymaps.resolve("ui.help")
	return renderer.format(session.statusline.items, session.statusline.notice, nil, {
		help_key = help_keys and help_keys[1],
	})
end

---@param session AtlasNativeDiffSession
function M.dispose(session)
	summary.dispose(session.statusline)
end

return M
