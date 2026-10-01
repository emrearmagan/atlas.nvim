local icons = require("atlas.ui.shared.icons")

local M = {}
local review_progress = { "󰝦", "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" }

---@param session AtlasDiffV2Session
function M.update(session)
	local result = session.data
	local review_data = result.review and result.review.data
	local files = session.explorer.files
	local count, additions, deletions = 0, 0, 0

	for _, file in ipairs(files) do
		additions = additions + (file.additions or 0)
		deletions = deletions + (file.deletions or 0)
		if session.reviewed_files[file.path] then
			count = count + 1
		end
	end

	local identity = result.pr and string.format("#%s %s", result.pr.id, result.pr.title)
		or string.format("%s...%s", result.base_revision:sub(1, 8), result.head_revision:sub(1, 8))
	local items = {
		{ text = identity, hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
		{ text = string.format("+%d", additions), hl_group = "AtlasFooterSuccess" },
		{ text = string.format("-%d", deletions), hl_group = "AtlasFooterError" },
	}

	if (result.review or next(session.reviewed_files)) and #files > 0 then
		items[#items + 1] = {
			text = string.format(
				"%s %d / %d reviewed",
				review_progress[math.ceil(count / #files * 8) + 1],
				count,
				#files
			),
			hl_group = count == #files and "AtlasFooterSuccess" or "AtlasFooterInfo",
			align = "right",
			priority = 40,
		}
	end

	local comments = review_data and review_data.comments or {}
	if #comments > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("comment"), #comments),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 30,
		}
	end

	local notes = result.notes and result.notes.items or {}
	if #notes > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.general("pin"), #notes),
			hl_group = "AtlasFooterNote",
			align = "right",
			priority = 20,
		}
	end

	local pending_comments = 0
	for _, comment in ipairs(comments) do
		if comment.pending then
			pending_comments = pending_comments + 1
		end
	end

	if pending_comments > 0 or (review_data and review_data.review.pending) then
		items[#items + 1] = {
			text = icons.pulls_status("inprogress")
				.. " "
				.. (pending_comments > 0 and string.format("%d pending", pending_comments) or "Pending review"),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 50,
		}
	end

	session.statusline:set_items(items)
end

return M
