---@class IssuesState
---@field active_view IssuesViewConfig|nil
---@field current_view IssuesViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field current_user IssueUser|nil
---@field issues Issue[]|nil
---@field issue_tree IssuesGroup[]|nil
---@field line_map table<integer, table>
---@field collapsed_issue_keys table<string, boolean>
---@field provider IssuesProvider|nil
---@field latest_request_tokens table<string, integer>
---@field request_seq number
---@field reloading_issue_keys table<string, integer>
---@field reload_spinner_frame string
local M = {
	active_view = nil,
	current_view = nil,
	is_loading = false,
	error = nil,
	current_user = nil,
	issues = nil,
	issue_tree = nil,
	line_map = {},
	collapsed_issue_keys = {},
	provider = nil,
	latest_request_tokens = {},
	request_seq = 0,
	reloading_issue_keys = {},
	reload_spinner_frame = "⠋",
}

---@param issue_key string
---@return string
function M.reload_key(issue_key)
	return tostring(issue_key)
end

---@param issue_key string
---@return boolean
function M.is_issue_reloading(issue_key)
	local key = M.reload_key(issue_key)
	return (tonumber(M.reloading_issue_keys[key]) or 0) > 0
end

function M.reset()
	M.active_view = nil
	M.current_view = nil
	M.is_loading = false
	M.error = nil
	M.current_user = nil
	M.issues = nil
	M.issue_tree = nil
	M.line_map = {}
	M.collapsed_issue_keys = {}
	M.provider = nil
	M.latest_request_tokens = {}
	M.request_seq = 0
	M.reloading_issue_keys = {}
	M.reload_spinner_frame = "⠋"
end

---@param issue_key string|nil
---@return boolean
function M.toggle_issue_collapsed(issue_key)
	local key = type(issue_key) == "string" and issue_key or ""
	if key == "" then
		return false
	end

	M.collapsed_issue_keys[key] = not (M.collapsed_issue_keys[key] == true)
	return true
end

---@return boolean
function M.toggle_current_issue_collapsed()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		return false
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	local key = type(issue) == "table" and tostring(issue.key or "") or ""
	return M.toggle_issue_collapsed(key)
end

---@return boolean
function M.toggle_all_issues_collapsed()
	local foldable_keys = {}
	for _, group in ipairs(M.issue_tree or {}) do
		local issue = type(group) == "table" and group.issue or nil
		local children = type(group) == "table" and group.children or nil
		local key = type(issue) == "table" and tostring(issue.key or "") or ""
		if key ~= "" and type(children) == "table" and #children > 0 then
			table.insert(foldable_keys, key)
		end
	end

	if #foldable_keys == 0 then
		return false
	end

	local should_expand = false
	for _, key in ipairs(foldable_keys) do
		if M.collapsed_issue_keys[key] == true then
			should_expand = true
			break
		end
	end

	M.collapsed_issue_keys = {}
	if should_expand then
		return true
	end

	for _, key in ipairs(foldable_keys) do
		M.collapsed_issue_keys[key] = true
	end
	return true
end

return M
