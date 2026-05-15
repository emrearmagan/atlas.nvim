local M = {}

---@return string[]
local function collect_logins()
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
	local conversation_state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

	local seen, logins = {}, {}
	local function add(login)
		local l = tostring(login or "")
		if l ~= "" and not seen[l] then
			seen[l] = true
			table.insert(logins, l)
		end
	end

	local pr = panel_state.current_pr
	if pr and pr.author then
		add(pr.author.nickname or pr.author.name)
	end

	if pr and type(pr._raw) == "table" then
		for _, list in ipairs({ pr._raw.assignees, pr._raw.reviewers }) do
			if type(list) == "table" then
				for _, u in ipairs(list) do
					if type(u) == "table" then
						add(u.username or u.name)
					end
				end
			end
		end
	end

	local cc = comments_state.comments
	if type(cc) == "table" then
		---@cast cc PullsComment[]
		for _, c in ipairs(cc) do
			if c.author then
				add(c.author.nickname or c.author.name)
			end
		end
	end
	local conv = conversation_state.comments
	if type(conv) == "table" then
		---@cast conv PullsComment[]
		for _, c in ipairs(conv) do
			if c.author then
				add(c.author.nickname or c.author.name)
			end
		end
	end

	return logins
end

---@return AtlasMarkdownCompletionProvider|nil
function M.build_completion()
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
			for _, login in ipairs(collect_logins()) do
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
