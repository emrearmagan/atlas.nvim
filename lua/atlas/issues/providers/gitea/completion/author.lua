local M = {}

---@return string[]
local function collect_logins()
	local issues_state = require("atlas.issues.state")
	local panel_state = require("atlas.issues.ui.panel.issue.state")
	local conversation_state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
	local seen, logins = {}, {}

	local function add(user)
		if type(user) ~= "table" then
			return
		end
		local login = vim.trim(tostring(user.account_id or user.login or ""))
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(logins, login)
		end
	end

	local function add_issue(issue)
		if type(issue) ~= "table" then
			return
		end
		add(issue.reporter)
		add(issue.assignee)
		for _, user in ipairs(type(issue._raw) == "table" and issue._raw.assignees or {}) do
			add(user)
		end
	end

	add(issues_state.current_user)
	add_issue(panel_state.current_issue)
	for _, issue in ipairs(issues_state.issues or {}) do
		add_issue(issue)
	end
	local comments = conversation_state.comments
	if type(comments) == "table" then
		for _, comment in ipairs(comments) do
			add(comment.author)
		end
	end
	table.sort(logins)
	return logins
end

---@return AtlasMarkdownCompletionProvider
function M.build_completion()
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = tostring(before or ""):match(".*@()[-%w_.]*$")
			return start_after_at and (start_after_at - 2) or nil
		end,
		complete = function(base)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local matches = {}
			for _, login in ipairs(collect_logins()) do
				if query == "" or login:lower():find(query, 1, true) == 1 then
					table.insert(matches, { word = "@" .. login, abbr = "@" .. login, menu = "mention" })
				end
			end
			return matches
		end,
		format_mention = function(author)
			local login = vim.trim(tostring((author or {}).account_id or ""))
			return login ~= "" and ("@" .. login) or ""
		end,
	}
end

return M
