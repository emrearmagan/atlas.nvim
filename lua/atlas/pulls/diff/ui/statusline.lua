local M = {}

local icons = require("atlas.ui.shared.icons")
local renderer = require("atlas.ui.statusline")
local spinner = require("atlas.ui.components.spinner")

local STATUSLINE = "%!v:lua.require'atlas.pulls.diff.ui.statusline'.current()"

---@class AtlasDiffStatuslineState
---@field notice AtlasStatuslineNoticeState
---@field spinner SpinnerInstance|nil
---@field closed boolean

---@return AtlasDiffStatuslineState
function M.new()
	return {
		notice = { text = "", hl_group = "AtlasFooterText", token = 0 },
		spinner = nil,
		closed = false,
	}
end

---@param win integer|nil
function M.attach(win)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = win, scope = "local" })
	end
end

---@param current AtlasDiffStatuslineState
local function stop_spinner(current)
	if current.spinner then
		current.spinner:stop()
		current.spinner = nil
	end
end

---@param level "loading"|"success"|"warn"|"error"|"info"
---@return string, string
local function notice_style(level)
	local icon = level == "loading" and "" or icons.general(level == "warn" and "warning" or level)
	local highlights = {
		loading = "AtlasFooterInfo",
		success = "AtlasFooterSuccess",
		warn = "AtlasFooterWarning",
		error = "AtlasFooterError",
		info = "AtlasFooterInfo",
	}
	return icon, highlights[level] or "AtlasFooterText"
end

---@param current AtlasDiffStatuslineState
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
function M.notify(current, level, message, duration)
	if current.closed then
		return
	end
	message = tostring(message):gsub("[\r\n]+", " | ")
	message = #message > 60 and message:sub(1, 57) .. "..." or message
	current.notice.token = current.notice.token + 1
	local token = current.notice.token
	stop_spinner(current)

	local icon, hl_group = notice_style(level)
	current.notice.hl_group = hl_group
	if level == "loading" then
		current.spinner = spinner.create({
			on_tick = function(frame)
				if not current.closed and current.notice.token == token then
					current.notice.text = string.format("%s %s", frame, message)
					vim.cmd("redrawstatus")
				end
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
		if not current.closed and current.notice.token == token then
			current.notice.text = ""
			current.notice.hl_group = "AtlasFooterText"
			vim.cmd("redrawstatus")
		end
	end, duration or 2500)
end

---@param current AtlasDiffStatuslineState
function M.dispose(current)
	current.closed = true
	current.notice.token = current.notice.token + 1
	stop_spinner(current)
end

---@param session AtlasDiffSession
---@return string
function M.render(session)
	local review = session.review
	local pr = review and review.pr
	local comments = review and review.data.comments or {}
	local identity = pr and string.format("#%s %s", tostring(pr.id), tostring(pr.title))
		or string.format(
			"%s...%s",
			tostring(session.source.base_revision):sub(1, 8),
			session.source.head_revision and tostring(session.source.head_revision):sub(1, 8) or "WORKTREE"
		)
	local state = session.viewer_state
	local items = {
		{ text = identity, hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
	}
	if state.additions and state.deletions then
		items[#items + 1] = { text = string.format("+%d", state.additions), hl_group = "AtlasFooterSuccess" }
		items[#items + 1] = { text = string.format("-%d", state.deletions), hl_group = "AtlasFooterError" }
	end
	if #comments > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("comment"), #comments),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 30,
		}
	end
	if #session.notes > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("pin"), #session.notes),
			hl_group = "AtlasFooterNote",
			align = "right",
			priority = 20,
		}
	end
	local pending = 0
	for _, comment in ipairs(comments) do
		if comment.state == "PENDING" then
			pending = pending + 1
		end
	end
	if pending > 0 or (review and review.data.review.pending) then
		items[#items + 1] = {
			text = icons.pulls_status("inprogress")
				.. " "
				.. (pending > 0 and string.format("%d pending", pending) or "Pending review"),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 50,
		}
	end
	return renderer.format(items, session.statusline.notice, nil, { help_key = session.help_key })
end

---@return string
function M.current()
	local session = require("atlas.pulls.diff.session").get()
	return session and M.render(session) or ""
end

return M
