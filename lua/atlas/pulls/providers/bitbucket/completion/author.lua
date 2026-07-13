local M = {}

-- Bitbucket comment/activity text often contains mentions as account IDs
-- (e.g. "@{<account_id>}"), not display names. We best-effort resolve them
-- using users known in the current PR detail (author/reviewers/participants).
--
---@param context AtlasPullsCommentCompletionContext
---@return PullsAuthor[]
local function collect_authors(context)
	local seen = {}
	local function add(author)
		if type(author) ~= "table" then
			return
		end
		local id = tostring(author.id or "")
		if id == "" or seen[id] then
			return
		end
		seen[id] = {
			id = id,
			name = tostring(author.name or ""),
			username = tostring(author.nickname or author.username or ""),
		}
	end

	local pr = context.pr
	if pr then
		add(pr.author)
	end

	local reviewers = context.reviewers or {}
	if type(reviewers) == "table" then
		---@cast reviewers PullsReviewer[]
		for _, r in ipairs(reviewers) do
			add({ id = r.nickname or r.name, name = r.name, nickname = r.nickname })
		end
	end

	for _, c in ipairs(context.comments) do
		add(c.author)
	end

	return vim.tbl_values(seen)
end

---@param authors PullsAuthor[]
---@return table<string, string>
local function build_map(authors)
	local map = {}
	for _, author in ipairs(authors or {}) do
		local id = tostring(author.id or "")
		local name = tostring(author.name or author.username or "")
		if id ~= "" and name ~= "" then
			map[id] = name
		end
	end
	return map
end

---@param mention_map table<string, string>
---@return { id: string, label: string }[]
local function to_mentions(mention_map)
	local users = {}
	for id, label in pairs(mention_map or {}) do
		if id ~= "" and label ~= "" then
			table.insert(users, { id = id, label = label })
		end
	end
	table.sort(users, function(a, b)
		return a.label:lower() < b.label:lower()
	end)
	return users
end

---@param text string
---@param authors PullsAuthor[]
---@return string
function M.resolve(text, authors)
	local raw = tostring(text or "")
	if raw:find("@{", 1, true) == nil then
		return raw
	end

	local mention_map = build_map(authors)
	return (
		raw:gsub("@{([^}]+)}", function(id)
			local name = mention_map[id]
			if name and name ~= "" then
				return "@" .. name
			end
			return "@{" .. id .. "}"
		end)
	)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider|nil
function M.build_completion(context)
	local mention_map = build_map(collect_authors(context))
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
			local users = to_mentions(mention_map)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local matches = {}
			for _, user in ipairs(users) do
				if query == "" or user.label:lower():find(query, 1, true) == 1 then
					table.insert(matches, {
						word = "@{" .. user.id .. "}",
						abbr = "@" .. user.label,
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
			local id = tostring((author or {}).id or "")
			if id ~= "" then
				return "@{" .. id .. "}"
			end
			local name = tostring((author or {}).nickname or (author or {}).username or (author or {}).name or "")
			return name ~= "" and ("@" .. name) or ""
		end,
	}
end

return M
