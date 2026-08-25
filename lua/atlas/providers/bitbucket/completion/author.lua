local M = {}

---@param context AtlasPullsCommentCompletionContext
---@return PullsAuthor[]
local function collect_authors(context)
	local authors = {}
	local function add(author)
		if type(author) ~= "table" then
			return
		end
		local id = tostring(author.id or "")
		if id == "" or authors[id] then
			return
		end
		local username = tostring(author.nickname or "")
		if username == "" then
			username = tostring(author.username or "")
		end
		local name = tostring(author.name or "")
		if name == "" then
			name = tostring(author.display_name or username)
		end
		authors[id] = {
			id = id,
			name = name,
			username = username,
		}
	end

	local pr = context.pr
	for _, author in ipairs((context.review_context or {}).authors or {}) do
		add(author)
	end
	if pr then
		add(pr.author)
		for _, reviewer in ipairs(pr.reviewers or {}) do
			add(reviewer)
		end
	end
	for _, items in ipairs({ context.comments or {}, context.tasks or {}, context.conversation or {} }) do
		for _, item in ipairs(items) do
			add(item.author)
		end
	end
	for _, reviewer in ipairs(context.reviewers or {}) do
		add(reviewer)
	end

	return vim.tbl_values(authors)
end

---@param authors PullsAuthor[]
---@return table<string, string>
local function build_map(authors)
	local mentions = {}
	for _, author in ipairs(authors) do
		local id = tostring(author.id or "")
		local name = tostring(author.name or "")
		if name == "" then
			name = tostring(author.username or "")
		end
		if id ~= "" and name ~= "" then
			mentions[id] = name
		end
	end
	return mentions
end

---@param text string
---@param mentions table<string, string>
---@return string
local function resolve(text, mentions)
	return (
		tostring(text or ""):gsub("@{([^}]+)}", function(id)
			return mentions[id] and ("@" .. mentions[id]) or ("@{" .. id .. "}")
		end)
	)
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

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider|nil
function M.for_pulls(context)
	local mention_map = build_map(collect_authors(context))
	return {
		trigger = "@",
		resolve_items = function()
			for _, items in ipairs({ context.comments or {}, context.tasks or {} }) do
				for _, item in ipairs(items) do
					item.content_display = resolve(item.content_raw, mention_map)
				end
			end
		end,
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
			local name = tostring((author or {}).nickname or "")
			if name == "" then
				name = tostring((author or {}).username or "")
			end
			if name == "" then
				name = tostring((author or {}).name or "")
			end
			return name ~= "" and ("@" .. name) or ""
		end,
	}
end

return M
