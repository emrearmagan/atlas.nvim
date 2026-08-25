local M = {}

---@param collect_logins fun(): string[]
---@param format_mention fun(author: IssueUser|PullsAuthor|nil): string
---@return AtlasMarkdownCompletionProvider
local function build_completion(collect_logins, format_mention)
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = tostring(before or ""):match(".*@()[-%w_]*$")
			if start_after_at == nil then
				return nil
			end
			return start_after_at - 2
		end,
		complete = function(base)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local matches = {}
			for _, login in ipairs(collect_logins()) do
				if query == "" or login:lower():find(query, 1, true) == 1 then
					table.insert(matches, {
						word = "@" .. login,
						abbr = "@" .. login,
						menu = "mention",
					})
				end
			end
			table.sort(matches, function(a, b)
				return tostring(a.abbr or "") < tostring(b.abbr or "")
			end)
			return matches
		end,
		format_mention = format_mention,
	}
end

---@return string[], fun(login: any)
local function login_collector()
	local seen = {}
	local logins = {}
	local function add(login)
		local value = tostring(login or "")
		if value ~= "" and not seen[value] then
			seen[value] = true
			table.insert(logins, value)
		end
	end
	return logins, add
end

---@param context AtlasIssuesCommentCompletionContext
---@return string[]
local function collect_issue_logins(context)
	local logins, add = login_collector()
	local issue = context.issue
	if issue then
		add(issue.reporter and issue.reporter.account_id)
		add(issue.assignee and issue.assignee.account_id)
		---@cast issue IssueDetails
		for _, assignee in ipairs(issue.assignees or {}) do
			add(assignee.account_id)
		end
	end
	for _, comment in ipairs(context.comments) do
		add(comment.author and comment.author.account_id)
	end
	return logins
end

---@param context AtlasPullsCommentCompletionContext
---@return string[]
local function collect_pull_logins(context)
	local logins, add = login_collector()
	local pr = context.pr
	for _, author in ipairs((context.review_context or {}).authors or {}) do
		add(author.nickname or author.username or author.name)
	end
	if pr and pr.author then
		add(pr.author.nickname or pr.author.name)
	end

	local reviewers = context.reviewers or {}
	if type(reviewers) == "table" then
		---@cast reviewers PullsReviewer[]
		for _, reviewer in ipairs(reviewers) do
			add(reviewer.nickname or reviewer.name)
		end
	end

	if pr then
		for _, assignee in ipairs(pr.assignees or {}) do
			add(assignee.username)
		end
	end

	for _, comment in ipairs(context.comments) do
		add(comment.author and (comment.author.nickname or comment.author.name))
	end

	return logins
end

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	return build_completion(function()
		return collect_issue_logins(context)
	end, function(author)
		---@cast author IssueUser|nil
		local handle = tostring((author or {}).account_id or "")
		return handle ~= "" and ("@" .. handle) or ""
	end)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	return build_completion(function()
		return collect_pull_logins(context)
	end, function(author)
		---@cast author PullsAuthor|nil
		local handle = tostring((author or {}).nickname or (author or {}).username or (author or {}).name or "")
		return handle ~= "" and ("@" .. handle) or ""
	end)
end

return M
