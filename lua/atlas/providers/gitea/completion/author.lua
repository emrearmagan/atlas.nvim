local M = {}

---@param value any
---@param seen table<string, boolean>
---@param logins string[]
local function add_login(value, seen, logins)
	local login = vim.trim(tostring(value or ""))
	if login == "" or seen[login] then
		return
	end
	seen[login] = true
	table.insert(logins, login)
end

---@param context AtlasIssuesCommentCompletionContext
---@return string[]
local function collect_issue_logins(context)
	local seen, logins = {}, {}
	local function add(user)
		if type(user) == "table" then
			add_login(user.account_id, seen, logins)
		end
	end

	add(context.current_user)
	local issue = context.issue
	if issue then
		add(issue.reporter)
		add(issue.assignee)
		---@cast issue GiteaIssueDetails
		for _, assignee in ipairs(issue.assignees or {}) do
			add(assignee)
		end
	end
	for _, comment in ipairs(context.comments or {}) do
		add(comment.author)
	end
	return logins
end

---@param context AtlasPullsCommentCompletionContext
---@return string[]
local function collect_pull_logins(context)
	local seen, logins = {}, {}
	local function add(user)
		if type(user) == "table" then
			add_login(user.username, seen, logins)
		end
	end

	for _, author in ipairs((context.review_context or {}).authors or {}) do
		add(author)
	end

	local pr = context.pr
	add(pr.author)
	for _, users in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
		for _, user in ipairs(users) do
			add(user)
		end
	end
	for _, reviewer in ipairs(context.reviewers or {}) do
		add(reviewer)
	end
	for _, comments in ipairs({ context.comments or {}, context.conversation or {} }) do
		for _, comment in ipairs(comments) do
			add(comment.author)
		end
	end
	return logins
end

---@param logins string[]
---@param format_mention fun(author: IssueUser|PullsAuthor|nil): string
---@return AtlasMarkdownCompletionProvider
local function completion(logins, format_mention)
	table.sort(logins)
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = tostring(before or ""):match(".*@()[-%w_.]*$")
			return start_after_at and (start_after_at - 2) or nil
		end,
		complete = function(base)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local matches = {}
			for _, login in ipairs(logins) do
				if query == "" or login:lower():find(query, 1, true) == 1 then
					table.insert(matches, { word = "@" .. login, abbr = "@" .. login, menu = "mention" })
				end
			end
			return matches
		end,
		format_mention = format_mention,
	}
end

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	return completion(collect_issue_logins(context), function(author)
		---@cast author IssueUser|nil
		local login = author and author.account_id or ""
		return login ~= "" and ("@" .. login) or ""
	end)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	return completion(collect_pull_logins(context), function(author)
		---@cast author PullsAuthor|nil
		local login = author and author.username or ""
		return login ~= "" and ("@" .. login) or ""
	end)
end

return M
