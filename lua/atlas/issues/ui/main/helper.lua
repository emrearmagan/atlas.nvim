local M = {}

local highlights = require("atlas.ui.shared.highlights")

---@param issue_type string|nil
---@return string
function M.issue_type_hl(issue_type)
	local lower = tostring(issue_type or ""):lower()
	if lower == "bug" then
		return "AtlasLogError"
	end
	if lower == "story" then
		return "AtlasTextPositive"
	end
	if lower == "epic" then
		return "AtlasJiraEpic"
	end
	if lower == "task" or lower == "sub-task" or lower == "subtask" then
		return "AtlasLogInfo"
	end
	if lower == "issue" then
		return "AtlasGHIssueOpen"
	end
	return "AtlasTextMuted"
end

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
		return "AtlasGHIssueKey"
	end

	return "AtlasJiraKey"
end

---@param status_id string|nil
---@return string
function M.status_hl(status_id)
	return highlights.dynamic_for_bg(status_id and ("jira-status:" .. status_id) or nil) or "AtlasTextMuted"
end

---@param priority string|nil
---@return string
function M.priority_hl(priority)
	local lower = tostring(priority or ""):lower()
	if lower == "highest" or lower == "high" or lower == "blocker" then
		return "AtlasLogError"
	end
	if lower == "medium" then
		return "AtlasTextWarning"
	end
	if lower == "low" or lower == "lowest" then
		return "AtlasTextPositive"
	end
	return "AtlasTextMuted"
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

---@param issues Issue[]
---@return IssuesGroup[]
function M.build_issue_tree(issues)
	local by_key = {}
	for _, issue in ipairs(issues or {}) do
		if type(issue) == "table" and type(issue.key) == "string" and issue.key ~= "" then
			by_key[issue.key] = {
				issue = issue,
				children = {},
			}
		end
	end

	for _, issue in ipairs(issues or {}) do
		if type(issue) == "table" and type(issue.parent) == "table" then
			local parent_key = tostring(issue.parent.key or "")
			local parent_group = by_key[parent_key]
			if parent_group then
				table.insert(parent_group.children, issue)
			end
		end
	end

	local roots = {}
	for _, issue in ipairs(issues or {}) do
		if type(issue) == "table" then
			local has_parent = type(issue.parent) == "table"
			local parent_key = has_parent and tostring(issue.parent.key or "") or ""
			local parent_group = parent_key ~= "" and by_key[parent_key] or nil
			if not parent_group then
				local group = by_key[tostring(issue.key or "")]
				if group then
					table.insert(roots, group)
				end
			end
		end
	end

	return roots
end

return M
