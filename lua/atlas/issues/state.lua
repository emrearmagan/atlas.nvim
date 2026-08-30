---@class IssuesState
---@field view IssuesViewConfig|nil
---@field bookmarks AtlasBookmarksState|nil
---@field query string
---@field is_loading boolean
---@field error string|nil
---@field current_user IssueUser|nil
---@field issues Issue[]
---@field current_page integer
---@field page_history IssuesPage[]
---@field issue_tree IssuesGroup[]
---@field collapsed_issue_keys table<string, boolean>
---@field provider IssuesProvider|nil
---@field provider_views IssuesViewConfig[]
---@field views IssuesViewConfig[]
---@field starred_items AtlasStarredItem[]
---@field reloading_issue_keys table<string, boolean>
---@field reload_spinner_frame string
local M = {
	view = nil,
	bookmarks = nil,
	query = "",
	is_loading = false,
	error = nil,
	current_user = nil,
	issues = {},
	current_page = 1,
	page_history = {},
	issue_tree = {},
	collapsed_issue_keys = {},
	provider = nil,
	provider_views = {},
	views = {},
	starred_items = {},
	reloading_issue_keys = {},
	reload_spinner_frame = "⠋",
}

---@generic T
---@param items T[]
---@param is_starred fun(item: T): boolean
---@return T[]
local function starred_first(items, is_starred)
	local first, rest = {}, {}
	for _, item in ipairs(items) do
		table.insert(is_starred(item) and first or rest, item)
	end
	vim.list_extend(first, rest)
	return first
end

---@param issues Issue[]
---@return IssuesGroup[]
local function build_issue_tree(issues)
	local by_key = {}
	for _, issue in ipairs(issues) do
		if issue.key ~= "" then
			by_key[issue.key] = { issue = issue, children = {} }
		end
	end

	for _, issue in ipairs(issues) do
		local parent = issue.parent and by_key[issue.parent.key]
		if parent ~= nil then
			table.insert(parent.children, issue)
		end
	end

	local roots = {}
	for _, issue in ipairs(issues) do
		local parent_key = issue.parent and issue.parent.key or ""
		if by_key[parent_key] == nil then
			local group = by_key[issue.key]
			if group ~= nil then
				table.insert(roots, group)
			end
		end
	end
	return roots
end

---@return IssuesViewConfig|nil
function M.search_view()
	local bookmarks = M.bookmarks
	if bookmarks ~= nil and M.view == bookmarks.tab then
		local selection = bookmarks.selection
		local view = selection and selection.kind == "bookmark" and selection.view or nil
		---@cast view IssuesViewConfig|nil
		return view
	end
	return M.view
end

---@param issues Issue[]
function M.set_issues(issues)
	M.issues = starred_first(issues, function(issue)
		return issue.is_starred == true
	end)
	M.issue_tree = starred_first(build_issue_tree(M.issues), function(group)
		if group.issue.is_starred then
			return true
		end
		for _, child in ipairs(group.children) do
			if child.is_starred then
				return true
			end
		end
		return false
	end)
end

---@param issue_key string
---@return boolean changed
function M.toggle_issue_collapsed(issue_key)
	if issue_key == "" then
		return false
	end
	M.collapsed_issue_keys[issue_key] = M.collapsed_issue_keys[issue_key] ~= true
	return true
end

---@return boolean changed
function M.toggle_all_issues_collapsed()
	local keys = {}
	local expand = false
	for _, group in ipairs(M.issue_tree) do
		if group.issue.key ~= "" and #group.children > 0 then
			table.insert(keys, group.issue.key)
			expand = expand or M.collapsed_issue_keys[group.issue.key] == true
		end
	end
	if #keys == 0 then
		return false
	end

	M.collapsed_issue_keys = {}
	if not expand then
		for _, key in ipairs(keys) do
			M.collapsed_issue_keys[key] = true
		end
	end
	return true
end

return M
