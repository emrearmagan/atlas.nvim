local M = {}

local icons = require("atlas.ui.shared.icons")
local statusline = require("atlas.ui.statusline")

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

	local published, pending = 0, 0
	if review then
		for _, comment in ipairs(review.comments) do
			if comment.state == "PENDING" then
				pending = pending + 1
			else
				published = published + 1
			end
		end
	end
	if published > 0 then
		result[#result + 1] = {
			text = string.format("%s %d", icons.general("comment"), published),
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
	if pending > 0 then
		result[#result + 1] = {
			text = string.format("%s %d", icons.pulls_status("inprogress"), pending),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 50,
		}
	end
	return result
end

---@param identity string
---@param additions integer|nil
---@param deletions integer|nil
---@param review AtlasReviewState|nil
---@param notes AtlasReviewNotesState|nil
---@return string
function M.render(identity, additions, deletions, review, notes)
	return statusline.format(M.items(identity, additions, deletions, review, notes), nil, nil, {
		help_key = "gA",
		left_padding = 3,
	})
end

return M
