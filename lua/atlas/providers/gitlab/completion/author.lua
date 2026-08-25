local M = {}

---@param value any
---@param seen table<string, boolean>
---@param usernames string[]
local function add_username(value, seen, usernames)
	local username = tostring(value or "")
	if username == "" or seen[username] then
		return
	end
	seen[username] = true
	table.insert(usernames, username)
end

---@param context AtlasIssuesCommentCompletionContext
---@return string[]
local function collect_issue_usernames(context)
	local seen, usernames = {}, {}
	local function add(user)
		if type(user) == "table" then
			add_username(user.account_id, seen, usernames)
		end
	end

	local issue = context.issue
	if issue then
		add(issue.reporter)
		add(issue.assignee)
		---@cast issue IssueDetails
		for _, assignee in ipairs(issue.assignees or {}) do
			add(assignee)
		end
	end
	for _, comment in ipairs(context.comments or {}) do
		add(comment.author)
	end

	return usernames
end

---@param context AtlasPullsCommentCompletionContext
---@return string[]
local function collect_pull_usernames(context)
	local seen, usernames = {}, {}

	for _, author in ipairs((context.review_context or {}).authors or {}) do
		add_username(author.nickname or author.username or author.name, seen, usernames)
	end

	local pr = context.pr
	if pr then
		add_username(pr.author and (pr.author.nickname or pr.author.name), seen, usernames)
		for _, users in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
			for _, user in ipairs(users) do
				add_username(user.username or user.nickname or user.name, seen, usernames)
			end
		end
	end

	for _, comment in ipairs(context.comments or {}) do
		local author = comment.author
		add_username(author and (author.nickname or author.name), seen, usernames)
	end
	for _, comment in ipairs(context.conversation or {}) do
		local author = comment.author
		add_username(author and (author.nickname or author.name), seen, usernames)
	end

	return usernames
end

---@param collect_usernames fun(): string[]
---@param format_mention fun(author: table|nil): string
---@return AtlasMarkdownCompletionProvider
local function build_completion(collect_usernames, format_mention)
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
			for _, username in ipairs(collect_usernames()) do
				if query == "" or username:lower():find(query, 1, true) == 1 then
					table.insert(matches, {
						word = "@" .. username,
						abbr = "@" .. username,
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

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	return build_completion(function()
		return collect_issue_usernames(context)
	end, function(author)
		---@cast author IssueUser|nil
		local username = tostring((author or {}).account_id or "")
		return username ~= "" and ("@" .. username) or ""
	end)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	return build_completion(function()
		return collect_pull_usernames(context)
	end, function(author)
		---@cast author PullsAuthor|nil
		local username = tostring((author or {}).nickname or (author or {}).username or (author or {}).name or "")
		return username ~= "" and ("@" .. username) or ""
	end)
end

return M
