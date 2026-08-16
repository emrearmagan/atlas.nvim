local M = {}

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.build_completion(context)
	local seen, logins = {}, {}
	local function add(user)
		if type(user) ~= "table" then
			return
		end
		local login = vim.trim(tostring(user.nickname or user.username or user.name or ""))
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(logins, login)
		end
	end

	local pr = context.pr
	for _, author in ipairs((context.review_context or {}).authors or {}) do
		add(author)
	end
	if pr then
		add(pr.author)
		for _, users in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
			for _, user in ipairs(users) do
				add(user)
			end
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
	table.sort(logins)

	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = tostring(before or ""):match(".*@()[-%w_.]*$")
			return start_after_at and (start_after_at - 2) or nil
		end,
		complete = function(base)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local result = {}
			for _, login in ipairs(logins) do
				if query == "" or login:lower():find(query, 1, true) == 1 then
					table.insert(result, { word = "@" .. login, abbr = "@" .. login, menu = "mention" })
				end
			end
			return result
		end,
		format_mention = function(author)
			local login = vim.trim(tostring((author or {}).nickname or (author or {}).username or ""))
			return login ~= "" and ("@" .. login) or ""
		end,
	}
end

return M
