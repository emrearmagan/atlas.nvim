local M = {}

---@return string[]
local function collect_logins()
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.comments.state")

	local seen = {}
	local logins = {}
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

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	if type(overview_state.reviewers) == "table" then
		for _, r in ipairs(overview_state.reviewers) do
			add(r.nickname or r.name)
		end
	end

	if pr and type(pr._raw) == "table" then
		local raw_assignees = type(pr._raw.assignees) == "table" and pr._raw.assignees or {}
		local nodes = type(raw_assignees.nodes) == "table" and raw_assignees.nodes or {}
		for _, node in ipairs(nodes) do
			if type(node) == "table" then
				add(node.login)
			end
		end
	end

	local snapshot = comments_state.snapshot
	if type(snapshot) == "table" then
		for _, t in ipairs(snapshot.general or {}) do
			add(t.root.author and (t.root.author.nickname or t.root.author.name))
			for _, r in ipairs(t.replies) do
				add(r.author and (r.author.nickname or r.author.name))
			end
		end
		for _, ft in ipairs(snapshot.file_threads or {}) do
			for _, t in ipairs(ft.threads or {}) do
				add(t.root.author and (t.root.author.nickname or t.root.author.name))
				for _, r in ipairs(t.replies) do
					add(r.author and (r.author.nickname or r.author.name))
				end
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
	}
end

return M
