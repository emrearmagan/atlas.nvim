local M = {}

---@param context AtlasPullsCommentCompletionContext
---@return string[]
local function collect_logins(context)
	local seen = {}
	local logins = {}
	local function add(login)
		local l = tostring(login or "")
		if l ~= "" and not seen[l] then
			seen[l] = true
			table.insert(logins, l)
		end
	end

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
		for _, r in ipairs(reviewers) do
			add(r.nickname or r.name)
		end
	end

	if pr then
		local raw_assignees = type(pr._raw.assignees) == "table" and pr._raw.assignees or {}
		local nodes = type(raw_assignees.nodes) == "table" and raw_assignees.nodes or {}
		for _, node in ipairs(nodes) do
			if type(node) == "table" then
				add(node.login)
			end
		end
	end

	for _, c in ipairs(context.comments) do
		add(c.author and (c.author.nickname or c.author.name))
	end

	return logins
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider|nil
function M.build_completion(context)
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
			for _, login in ipairs(collect_logins(context)) do
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
		format_mention = function(author)
			local handle = tostring((author or {}).nickname or (author or {}).username or (author or {}).name or "")
			return handle ~= "" and ("@" .. handle) or ""
		end,
	}
end

return M
