local M = {}

---@class JiraMentionUser
---@field id string
---@field label string

---@param context AtlasIssuesCommentCompletionContext
---@return JiraMentionUser[]
---@return table<string, integer> label_counts
local function collect_users(context)
	local seen = {}
	local label_counts = {}
	---@type JiraMentionUser[]
	local users = {}

	---@param user AtlasUser|nil
	local function add(user)
		if user == nil then
			return
		end

		local id = vim.trim(user.id or "")
		local label = vim.trim(user.name)
		if id == "" or label == "" or seen[id] then
			return
		end

		seen[id] = true
		table.insert(users, { id = id, label = label })
		local label_key = label:lower()
		label_counts[label_key] = (label_counts[label_key] or 0) + 1
	end

	add(context.issue.assignee)
	add(context.issue.reporter)
	for _, comment in ipairs(context.comments) do
		add(comment.author)
	end

	table.sort(users, function(a, b)
		return a.label:lower() < b.label:lower()
	end)

	return users, label_counts
end

---@param author AtlasUser|nil
---@return string
local function resolve_mention(author)
	if author == nil then
		return ""
	end
	local mention_id = vim.trim(author.id or "")
	local mention_label = vim.trim(author.name)
	if mention_label == "" and mention_id == "" then
		return ""
	end
	if mention_label == "" then
		return "@" .. mention_id
	end
	if mention_id == "" then
		return "@" .. mention_label
	end
	return string.format("[@%s](atlas-mention:%s)", mention_label, mention_id)
end

---@param context AtlasIssuesCommentCompletionContext
---@return AtlasMarkdownCompletionProvider
function M.for_issues(context)
	return {
		trigger = "@",
		find_start = function(before)
			local start_after_at = tostring(before or ""):match(".*@()[-%w_ ]*$")
			if start_after_at == nil then
				return nil
			end
			return start_after_at - 2
		end,
		complete = function(base)
			local query = vim.trim(tostring(base or "")):gsub("^@", ""):lower()
			local users, label_counts = collect_users(context)
			local matches = {}
			for _, user in ipairs(users) do
				local id = user.id
				local label = user.label
				if query == "" or label:lower():find(query, 1, true) == 1 then
					local use_simple_label = label_counts[label:lower()] == 1
					local shown_abbr = use_simple_label and ("@" .. label) or string.format("@%s (%s)", label, id)
					local insert_word = resolve_mention({
						id = id,
						name = label,
					})
					table.insert(matches, {
						word = insert_word,
						abbr = shown_abbr,
						menu = "mention",
					})
				end
			end
			return matches
		end,
		format_mention = resolve_mention,
	}
end

return M
