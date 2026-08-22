local M = {}

---@return string[]
local function collect_logins()
	local issues_state = require("atlas.issues.state")
	local panel_state = require("atlas.issues.ui.panel.issue.state")
	local conversation_state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
	local seen, logins = {}, {}

	---@param login string|nil
	local function add_login(login)
		if not login then
			return
		end
		login = vim.trim(login)
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(logins, login)
		end
	end

	---@param user IssueUser|nil
	local function add(user)
		add_login(user and user.account_id)
	end

	local function add_issue(issue)
		if not issue then
			return
		end
		add(issue.reporter)
		add(issue.assignee)
		for _, user in ipairs(issue._raw.assignees) do
			add_login(user.login)
		end
	end

	add(issues_state.current_user)
	add_issue(panel_state.current_issue)
	for _, issue in ipairs(issues_state.issues or {}) do
		add_issue(issue)
	end
	local comments = conversation_state.comments
	if comments and comments ~= "loading" then
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
			local start_after_at = before:match(".*@()[-%w_.]*$")
			return start_after_at and (start_after_at - 2) or nil
		end,
		complete = function(base)
			local query = vim.trim(base):gsub("^@", ""):lower()
			local matches = {}
			for _, login in ipairs(collect_logins()) do
				if query == "" or login:lower():find(query, 1, true) == 1 then
					table.insert(matches, { word = "@" .. login, abbr = "@" .. login, menu = "mention" })
				end
			end
			return matches
		end,
		format_mention = function(author)
			---@cast author IssueUser|nil
			local login = author and author.account_id or ""
			return login ~= "" and ("@" .. login) or ""
		end,
	}
end

return M
