local M = {}

---@param context AtlasPullsCommentCompletionContext
---@return table<string, string>
local function collect_pull_authors(context)
	local authors = {}
	---@param author PullsAuthor|nil
	local function add(author)
		if author then
			authors[author.id] = author.name
		end
	end

	add(context.pr.author)
	for _, author in ipairs((context.review_context or {}).mention_candidates or {}) do
		add(author)
	end
	for _, reviewer in ipairs(context.pr.reviewers or {}) do
		add(reviewer)
	end
	for _, reviewer in ipairs(context.reviewers or {}) do
		add(reviewer)
	end
	for _, items in ipairs({ context.comments, context.conversation or {} }) do
		for _, item in ipairs(items) do
			add(item.author)
		end
	end
	return authors
end

---@param context AtlasIssuesCommentCompletionContext
---@return table<string, string>
local function collect_issue_authors(context)
	local authors = {}
	---@param author IssueUser|nil
	local function add(author)
		if author then
			authors[author.account_id] = author.display_name
		end
	end

	add(context.issue.reporter)
	add(context.issue.assignee)
	for _, assignee in ipairs((context.details or {}).assignees or {}) do
		add(assignee)
	end
	for _, comment in ipairs(context.comments) do
		add(comment.author)
	end
	return authors
end

---@param authors table<string, string>
---@param format_mention fun(author: IssueUser|PullsAuthor|nil): string
---@return AtlasMarkdownCompletionProvider
local function build_completion(authors, format_mention)
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = before:match(".*@()[-%w_]*$")
			return start_after_at and start_after_at - 2 or nil
		end,
		complete = function(base)
			local query = vim.trim(base):gsub("^@", ""):lower()
			local matches = {}
			for id, name in pairs(authors) do
				if query == "" or name:lower():find(query, 1, true) == 1 then
					table.insert(matches, {
						word = "@<" .. id .. ">",
						abbr = "@" .. name,
						menu = "mention",
					})
				end
			end
			table.sort(matches, function(a, b)
				return a.abbr < b.abbr
			end)
			return matches
		end,
		format_mention = format_mention,
	}
end

---@param text string
---@param authors table<string, string>
---@return string
local function resolve_mentions(text, authors)
	local display = text:gsub("@<([^>]+)>", function(id)
		return authors[id] and ("@" .. authors[id]) or ("@<" .. id .. ">")
	end)
	return display
end

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	local authors = collect_issue_authors(context)
	local completion = build_completion(authors, function(author)
		---@cast author IssueUser|nil
		return author and ("@<" .. author.account_id .. ">") or ""
	end)
	completion.resolve_items = function()
		for _, comment in ipairs(context.comments) do
			comment.body_display = resolve_mentions(comment.body or "", authors)
		end
	end
	return completion
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	local authors = collect_pull_authors(context)
	local completion = build_completion(authors, function(author)
		---@cast author PullsAuthor|nil
		return author and ("@<" .. author.id .. ">") or ""
	end)
	completion.resolve_items = function()
		for _, items in ipairs({ context.comments, context.conversation or {} }) do
			for _, item in ipairs(items) do
				item.content_display = resolve_mentions(item.content_raw, authors)
			end
		end
	end
	return completion
end

return M
