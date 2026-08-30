local M = {}

---@param context AtlasPullsCommentCompletionContext
---@return table<string, string>
local function collect_authors(context)
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

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_pulls(context)
	local authors = collect_authors(context)
	return {
		trigger = "@",
		resolve_items = function()
			for _, items in ipairs({ context.comments, context.conversation or {} }) do
				for _, item in ipairs(items) do
					item.content_display = item.content_raw:gsub("@<([^>]+)>", function(id)
						return authors[id] and ("@" .. authors[id]) or ("@<" .. id .. ">")
					end)
				end
			end
		end,
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
		format_mention = function(author)
			return author and ("@<" .. author.id .. ">") or ""
		end,
	}
end

return M
