local M = {}

---@class JiraMentionUser
---@field id string
---@field label string

---@param context AtlasIssuesCommentCompletionContext
---@return JiraMentionUser[]
local function collect_users(context)
	local seen = {}
	---@type JiraMentionUser[]
	local users = {}

	---@param user IssueUser|nil
	local function add(user)
		if user == nil then
			return
		end

		local id = vim.trim(tostring(user.account_id or ""))
		local label = vim.trim(tostring(user.display_name or ""))
		if id == "" or label == "" or seen[id] then
			return
		end

		seen[id] = true
		table.insert(users, { id = id, label = label })
	end

	add(context.issue.assignee)
	add(context.issue.reporter)
	for _, comment in ipairs(context.comments) do
		add(comment.author)
	end

	table.sort(users, function(a, b)
		return a.label:lower() < b.label:lower()
	end)

	return users
end

---@param context AtlasIssuesCommentCompletionContext
---@return table<string, JiraMentionUser>
local function build_map(context)
	local map = {}
	for _, user in ipairs(collect_users(context)) do
		local id = vim.trim(user.id)
		local label = vim.trim(user.label)
		if id ~= "" and label ~= "" then
			map[id] = { id = id, label = label }
		end
	end
	return map
end

---@param mention_map table<string, JiraMentionUser>
---@param label string
---@return boolean
local function is_unique_label(mention_map, label)
	local target = vim.trim(tostring(label or "")):lower()
	if target == "" then
		return false
	end
	local count = 0
	for _, user in pairs(mention_map) do
		if vim.trim(user.label):lower() == target then
			count = count + 1
			if count > 1 then
				return false
			end
		end
	end
	return true
end

---@param author IssueUser|nil
---@return string
local function resolve_mention(author)
	if author == nil then
		return ""
	end
	local mention_id = vim.trim(tostring(author.account_id or ""))
	local mention_label = vim.trim(author.display_name)
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
			local mention_map = build_map(context)
			local matches = {}
			for _, user in pairs(mention_map) do
				local id = user.id
				local label = user.label
				if id ~= "" and label ~= "" and (query == "" or label:lower():find(query, 1, true) == 1) then
					local use_simple_label = is_unique_label(mention_map, label)
					local shown_abbr = use_simple_label and ("@" .. label) or string.format("@%s (%s)", label, id)
					local insert_word = resolve_mention({
						account_id = id,
						display_name = label,
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
