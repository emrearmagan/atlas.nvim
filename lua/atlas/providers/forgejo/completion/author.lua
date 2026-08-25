local M = {}

---@param login any
---@param seen table<string, boolean>
---@param logins string[]
local function add_login(login, seen, logins)
	local value = vim.trim(tostring(login or ""))
	if value == "" or seen[value] then
		return
	end
	seen[value] = true
	table.insert(logins, value)
end

---@param context AtlasIssuesCommentCompletionContext
---@return string[]
local function issue_logins(context)
	local seen, logins = {}, {}
	local function add(user)
		add_login(user and user.account_id, seen, logins)
	end

	local issue = context.issue
	add(issue.reporter)
	add(issue.assignee)
	for _, assignee in ipairs((context.details or {}).assignees or {}) do
		add(assignee)
	end
	for _, comment in ipairs(context.comments or {}) do
		add(comment.author)
	end
	table.sort(logins)
	return logins
end

---@param context AtlasPullsCommentCompletionContext
---@return string[]
local function pull_logins(context)
	local seen, logins = {}, {}
	local function add(user)
		add_login(user and user.username, seen, logins)
	end

	for _, author in ipairs((context.review_context or {}).mention_candidates or {}) do
		add(author)
	end
	local pr = context.pr
	add(pr.author)
	for _, user in ipairs(pr.reviewers or {}) do
		add(user)
	end
	for _, assignee in ipairs((context.details or {}).assignees or {}) do
		add(assignee)
	end
	for _, reviewer in ipairs(context.reviewers or {}) do
		add(reviewer)
	end
	for _, comments in ipairs({ context.comments or {}, context.conversation or {} }) do
		for _, comment in ipairs(comments) do
			add(comment.author)
		end
	end
	table.sort(logins)
	return logins
end

---@param logins string[]
---@param format_mention fun(author: IssueUser|PullsAuthor|nil): string
---@return AtlasMarkdownCompletionProvider
local function completion(logins, format_mention)
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
	return completion(issue_logins(context), function(author)
		---@cast author IssueUser|nil
		local login = author and author.account_id or ""
		return login ~= "" and ("@" .. login) or ""
	end)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	return completion(pull_logins(context), function(author)
		---@cast author PullsAuthor|nil
		local login = author and author.username or ""
		return login ~= "" and ("@" .. login) or ""
	end)
end

return M
