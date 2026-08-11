local M = {}

local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local statusline = require("atlas.ui.statusline")

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

---@param current AtlasDiffStatuslineState
local function stop_spinner(current)
	if current.spinner then
		current.spinner:stop()
		current.spinner = nil
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

---@param current AtlasDiffStatuslineState
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
function M.notify(current, level, message, duration)
	if current.closed then
		return
	end
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
				if current.closed or current.notice.token ~= token then
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
		if current.closed or current.notice.token ~= token then
			return
		end
		current.notice.text = ""
		current.notice.hl_group = "AtlasFooterText"
		vim.cmd("redrawstatus")
	end, duration or 2500)
end

---@param current AtlasDiffStatuslineState
function M.dispose(current)
	current.closed = true
	current.notice.token = current.notice.token + 1
	stop_spinner(current)
end

---@param identity string
---@param additions integer|nil
---@param deletions integer|nil
---@param review AtlasReviewState|nil
---@param notes AtlasReviewNotesState|nil
---@return AtlasStatuslineSegment[]
function M.items(identity, additions, deletions, review, notes)
	local result = {
		{ text = identity, hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
	}
	if additions and deletions then
		result[#result + 1] = { text = string.format("+%d", additions), hl_group = "AtlasFooterSuccess" }
		result[#result + 1] = { text = string.format("-%d", deletions), hl_group = "AtlasFooterError" }
	end

	local comment_count = review and #review.data.comments or 0
	if comment_count > 0 then
		result[#result + 1] = {
			text = string.format("%s %d", icons.general("comment"), comment_count),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 30,
		}
	end
	local note_count = notes and #notes.items or 0
	if note_count > 0 then
		result[#result + 1] = {
			text = string.format("%s %d", icons.general("pin"), note_count),
			hl_group = "AtlasFooterNote",
			align = "right",
			priority = 20,
		}
	end
	if review then
		local pending_comments = 0
		for _, comment in ipairs(review.data.comments) do
			if comment.state == "PENDING" then
				pending_comments = pending_comments + 1
			end
		end
		if pending_comments > 0 or review.data.review.pending then
			local label = pending_comments > 0 and string.format("%d pending", pending_comments) or "Pending review"
			result[#result + 1] = {
				text = icons.pulls_status("inprogress") .. " " .. label,
				hl_group = "AtlasFooterWarning",
				align = "right",
				priority = 50,
			}
		end
	end
	return result
end

---@param identity string
---@param additions integer|nil
---@param deletions integer|nil
---@param review AtlasReviewState|nil
---@param notes AtlasReviewNotesState|nil
---@param current AtlasDiffStatuslineState|nil
---@return string
function M.render(identity, additions, deletions, review, notes, current)
	return statusline.format(M.items(identity, additions, deletions, review, notes), current and current.notice, nil, {
		help_key = "gA",
		left_padding = 3,
	})
end

return M
