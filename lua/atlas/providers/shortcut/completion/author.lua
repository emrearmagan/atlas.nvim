local M = {}

---@class ShortcutMentionCandidate
---@field mention_name string
---@field display_name string

---@param context AtlasIssuesCommentCompletionContext
---@return ShortcutMentionCandidate[]
local function participants(context)
	local users = {}
	local seen = {}

	---@param user IssueUser|nil
	local function add(user)
		if user == nil then
			return
		end
		---@cast user ShortcutIssueUser
		local mention_name = user.mention_name
		if not mention_name or seen[mention_name] then
			return
		end
		seen[mention_name] = true
		table.insert(users, { mention_name = mention_name, display_name = user.display_name })
	end

	add(context.issue.assignee)
	add(context.issue.reporter)
	if context.details then
		for _, assignee in ipairs(context.details.assignees) do
			add(assignee)
		end
	end
	for _, comment in ipairs(context.comments) do
		add(comment.author)
	end

	table.sort(users, function(left, right)
		return left.mention_name < right.mention_name
	end)
	return users
end

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = before:match(".*@()[-%w_.]*$")
			return start_after_at and start_after_at - 2 or nil
		end,
		complete = function(base)
			local query = base:gsub("^@", ""):lower()
			local matches = {}
			for _, user in ipairs(participants(context)) do
				if query == "" or user.mention_name:lower():find(query, 1, true) == 1 then
					table.insert(matches, {
						word = "@" .. user.mention_name,
						abbr = "@" .. user.mention_name,
						menu = user.display_name,
					})
				end
			end
			return matches
		end,
		format_mention = function(author)
			if author == nil then
				return ""
			end
			---@cast author ShortcutIssueUser
			return author.mention_name and ("@" .. author.mention_name) or ""
		end,
	}
end

return M
