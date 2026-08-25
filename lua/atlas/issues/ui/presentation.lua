local M = {}

local highlights = require("atlas.ui.shared.highlights")

---@param _title string|nil
---@return string
function M.issue_title_hl(_title)
	return "Normal"
end

---@param key string|nil
---@return string
function M.issue_hl(key)
	local lower = tostring(key or ""):lower()
	if lower == "" or lower == "none" then
		return "LineNr"
	end
	if lower:find("#", 1, true) then
		return "AtlasTextMuted"
	end

	return "AtlasJiraKey"
end

---@param status_id string|nil
---@return string
function M.status_hl(status_id)
	return highlights.dynamic_for_bg(status_id and ("jira-status:" .. status_id) or nil) or "AtlasTextMuted"
end

---@param name string|IssueUser|nil
---@return string
function M.person_hl(name)
	if type(name) == "table" then
		name = name.display_name
	end

	if type(name) ~= "string" then
		return "AtlasTextMutedItalic"
	end

	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unassigned" or lower == "none" then
		return "AtlasTextMutedItalic"
	end

	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

return M
