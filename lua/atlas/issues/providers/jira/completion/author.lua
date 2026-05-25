local M = {}

---@class JiraMentionUser
---@field id string
---@field label string

---@return JiraMentionUser[]
local function collect_users()
	local conversation_state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
	local panel_state = require("atlas.issues.ui.panel.issue.state")
	local issues_state = require("atlas.issues.state")

	local seen = {}
	---@type JiraMentionUser[]
	local users = {}

	local function add(user)
		if type(user) ~= "table" then
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

	add(issues_state.current_user)
	add((panel_state.current_issue or {}).assignee)
	add((panel_state.current_issue or {}).reporter)
	for _, issue in ipairs(issues_state.issues or {}) do
		add((issue or {}).assignee)
		add((issue or {}).reporter)
	end
	local conversation_comments = conversation_state.comments
	if type(conversation_comments) == "table" then
		for _, comment in ipairs(conversation_comments) do
			add((comment or {}).author)
		end
	end

	table.sort(users, function(a, b)
		return tostring(a.label or ""):lower() < tostring(b.label or ""):lower()
	end)

	return users
end

---@return table<string, JiraMentionUser>
local function build_map()
	local map = {}
	for _, user in ipairs(collect_users()) do
		local id = vim.trim(tostring(user.id or ""))
		local label = vim.trim(tostring(user.label or ""))
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
	for _, user in pairs(mention_map or {}) do
		if vim.trim(tostring((user or {}).label or "")):lower() == target then
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
	local mention_id = vim.trim(tostring((author or {}).account_id or ""))
	local mention_label = vim.trim(tostring((author or {}).display_name or ""))
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

---@return AtlasMarkdownCompletionProvider
function M.build_completion()
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
			local mention_map = build_map()
			local matches = {}
			for _, user in pairs(mention_map) do
				local id = tostring((user or {}).id or "")
				local label = tostring((user or {}).label or "")
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

---@param text string
---@return string
function M.resolve(text)
	local raw = tostring(text or "")
	if raw == "" then
		return ""
	end

	local mention_map = build_map()

	local resolved = raw:gsub("%[@([^%]]+)%]%((atlas%-mention:([^%)]+))%)", function(label, _, id)
		local entry = mention_map[tostring(id or "")]
		local name = entry and entry.label or nil
		if name ~= nil and name ~= "" then
			return "@" .. name
		end

		local fallback = vim.trim(tostring(label or ""))
		if fallback:sub(1, 1) == "@" then
			return fallback
		end
		return fallback ~= "" and ("@" .. fallback) or ""
	end)

	resolved = resolved:gsub("%[@([^%]]+)%]%{mention:([^}]+)%}", function(label, id)
		local entry = mention_map[tostring(id or "")]
		local name = entry and entry.label or nil
		if name ~= nil and name ~= "" then
			return "@" .. name
		end

		local fallback = vim.trim(tostring(label or ""))
		if fallback:sub(1, 1) == "@" then
			return fallback
		end
		return fallback ~= "" and ("@" .. fallback) or ""
	end)

	return resolved
end

return M
