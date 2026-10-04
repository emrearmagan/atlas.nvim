local M = {}

---@param context AtlasPullsCommentContext
---@return table<string, string>
local function mention_names(context)
	local names = {}
	local data = context.data or {}

	---@param author PullsAuthor|nil
	local function add(author)
		if not author then
			return
		end

		local id = tostring(author.id or "")
		if id == "" or names[id] then
			return
		end

		local name = author.name
		if not name or name == "" then
			name = author.nickname
		end
		if not name or name == "" then
			name = author.username or ""
		end
		names[id] = name
	end

	for _, author in ipairs((context.review_context or {}).mention_candidates or {}) do
		add(author)
	end
	add(context.pr.author)
	for _, reviewer in ipairs(context.pr.reviewers or {}) do
		add(reviewer)
	end
	for _, items in ipairs({ data.comments or {}, data.tasks or {}, context.conversation or {} }) do
		for _, item in ipairs(items) do
			add(item.author)
		end
	end
	for _, reviewers in ipairs({ data.reviewers or {}, context.reviewers or {} }) do
		for _, reviewer in ipairs(reviewers) do
			add(reviewer)
		end
	end

	return names
end

---@param context AtlasPullsCommentContext
---@return fun(text: string): string
function M.formatter(context)
	local names = mention_names(context)
	return function(text)
		return (
			text:gsub("@{([^}]+)}", function(id)
				local name = names[id]
				return name and name ~= "" and ("@" .. name) or nil
			end)
		)
	end
end

---@param context AtlasPullsCommentContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	local users = {}
	for id, name in pairs(mention_names(context)) do
		if name ~= "" then
			users[#users + 1] = { word = "@{" .. id .. "}", abbr = "@" .. name, menu = "mention" }
		end
	end
	table.sort(users, function(a, b)
		return a.abbr < b.abbr
	end)

	return {
		trigger = "@",
		find_start = function(before)
			local start = before:match(".*@()[-%w_]*$")
			return start and start - 2 or nil
		end,
		complete = function(base)
			local query = vim.trim(base):gsub("^@", ""):lower()
			local matches = {}
			for _, user in ipairs(users) do
				if user.abbr:sub(2):lower():find(query, 1, true) == 1 then
					matches[#matches + 1] = user
				end
			end
			return matches
		end,
		format_mention = function(author)
			if not author then
				return ""
			end

			local id = tostring(author.id or "")
			if id ~= "" then
				return "@{" .. id .. "}"
			end

			local name = author.nickname
			if not name or name == "" then
				name = author.username
			end
			if not name or name == "" then
				name = author.name or ""
			end
			return name ~= "" and ("@" .. name) or ""
		end,
	}
end

return M
