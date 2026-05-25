local M = {}

local highlights = require("atlas.ui.shared.highlights")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.state")

local PR_ICON = icons.pulls("pr")
local MERGED_PR_ICON = icons.pulls("merged_pr")
local DECLINED_PR_ICON = icons.pulls("declined_pr")
local REPO_ICON = icons.pulls("repo")
local TASKS_ICON = icons.pulls("tasks")

local PR_STATE_ICON = {
	open = PR_ICON,
	draft = PR_ICON,
	merged = MERGED_PR_ICON,
	declined = DECLINED_PR_ICON,
}

local PR_STATE_ICON_HL = {
	open = "AtlasPROpen",
	draft = "AtlasPRDraft",
	merged = "AtlasPRMerged",
	declined = "AtlasPRDeclined",
}

---@param pr PullRequest
---@return string, string
local function pr_icon_and_hl(pr)
	local s = tostring(pr.state or ""):lower()
	return PR_STATE_ICON[s] or PR_ICON, PR_STATE_ICON_HL[s] or "AtlasPROpen"
end

---@param pr PullRequest
---@return string
local function pr_icon_or_spinner(pr)
	if state.is_pr_reloading(pr.repo_full_name, pr.id) then
		return state.reload_spinner_frame or "⠋"
	end
	local icon = pr_icon_and_hl(pr)
	return icon
end

---@param name string|nil
---@return string
function M.author_hl(name)
	if type(name) ~= "string" then
		return "AtlasTextMutedItalic"
	end
	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unknown" or lower == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param repo string|nil
---@return string
function M.repo_hl(repo)
	if type(repo) ~= "string" then
		return "AtlasTextMutedItalic"
	end
	local lower = vim.trim(repo):lower()
	if lower == "" or lower == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param pr_state string|nil
---@return string
function M.pr_state_hl(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "AtlasPROpenChip"
	end
	if lower == "merged" then
		return "AtlasPRMergedChip"
	end
	if lower == "declined" then
		return "AtlasPRDeclinedChip"
	end
	if lower == "draft" then
		return "AtlasPRDraftChip"
	end
	return "AtlasTextMuted"
end

---@param state_str string|nil
---@return string
function M.status_badge_hl(state_str)
	local lower = tostring(state_str or ""):lower()
	if lower == "" then
		return "AtlasTextMuted"
	end
	return highlights.dynamic_for_bg("pr-state:" .. lower) or "AtlasTextMuted"
end

---@param view AtlasPullsViewConfig|nil
---@return string
function M.view_id(view)
	if view == nil then
		return "default"
	end
	return view.key or view.name or "default"
end

---@param a AtlasPullsViewConfig|nil
---@param b AtlasPullsViewConfig|nil
---@return boolean
function M.same_view(a, b)
	if a == nil and b == nil then
		return true
	end
	if a == nil or b == nil then
		return false
	end
	return M.view_id(a) == M.view_id(b)
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	if col.key == "name" and row.kind == "repo" then
		local hl_group = highlights.dynamic_for(row.repo_full_name)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "name" and row.kind == "pr" then
		local is_reloading = row._pr_reloading == true
		local icon_hl = is_reloading and "AtlasTextMuted" or (row._pr_icon_hl or "AtlasPROpen")
		local pr_icon = row._pr_icon_str or PR_ICON
		local icon_start = string.find(ctx.text or "", pr_icon, 1, true)
		if icon_start ~= nil then
			local start_col = icon_start - 1
			return { { start_col = start_col, end_col = start_col + #pr_icon, hl_group = icon_hl } }
		end
		local frame_len = #(state.reload_spinner_frame or "⠋")
		return { { start_col = 0, end_col = frame_len, hl_group = icon_hl } }
	end
	if col.key == "pr_icon" then
		local is_reloading = row.kind == "pr" and row._pr_reloading == true
		local hl_group = is_reloading and "AtlasTextMuted"
			or (row.kind == "pr" and (row._pr_icon_hl or "AtlasPROpen") or "AtlasTextMuted")
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "branch" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "created" or col.key == "updated" or (row.kind == "meta" and col.key == "repo_pr") then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "author" then
		local hl_group = M.author_hl(row.author_hl or row.author)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "repo" then
		local hl_group = M.repo_hl(row.repo_hl or row.repo)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "status" then
		local hl_group = M.status_badge_hl(row.status_raw)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	return nil
end

---@param groups PullsGroup[]|nil
---@param current_user PullsUser|nil
---@return table[]
function M.build_footer_items(groups, current_user)
	local repos = groups or {}
	local pr_count = 0
	local repo_names = {}
	local seen = {}
	for _, group in ipairs(repos) do
		pr_count = pr_count + #(group.prs or {})
		local name = group.repo.name
		if name ~= nil and name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(repo_names, name)
		end
	end
	local items = {
		{
			text = string.format("%s %d PR%s", PR_ICON, pr_count, pr_count == 1 and "" or "s"),
			hl_group = "AtlasLogInfo",
		},
	}
	local user_name = tostring((current_user or {}).username or (current_user or {}).name or "")
	if user_name ~= "" then
		table.insert(items, {
			text = string.format("%s @%s", icons.general("user"), user_name),
			hl_group = "AtlasFooterText",
		})
	end
	if #repo_names > 0 then
		table.insert(items, {
			text = string.format("%s %s", REPO_ICON, table.concat(repo_names, ", ")),
			hl_group = "AtlasFooterText",
		})
	end
	return items
end

---@return table[]
local function compact_columns()
	local cols = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "repo_pr", name = "PR", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "tasks", name = TASKS_ICON, min_width = 2, can_grow = false, header_hl = "AtlasColumnHeader" },
	}
	vim.list_extend(cols, {
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "repo",
			name = string.format("%s Repo", REPO_ICON),
			min_width = 5,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	})
	return cols
end

---@param groups PullsGroup[]|nil
---@return { columns: table, rows: table[] }
function M.build_compact_table(groups)
	local rows = {}
	for _, group in ipairs(groups or {}) do
		local repo_label = group.repo.name or ""
		for _, pr in ipairs(group.prs or {}) do
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local author_name = (pr.author and pr.author.name) and pr.author.name or ""
			local src = (pr.source and pr.source.branch) or ""
			local dst = (pr.destination and pr.destination.branch) or ""
			local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
			local state_str = tostring(pr.state or "")
			local state_label = state_str ~= ""
					and (" " .. state_str:sub(1, 1):upper() .. state_str:sub(2):lower() .. " ")
				or ""
			local author_display = utils.shorten_name(author_name, 20)
			local icon, icon_hl = pr_icon_and_hl(pr)
			table.insert(rows, {
				kind = "pr",
				pr_icon = pr_icon_or_spinner(pr),
				_pr_reloading = is_reloading,
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				repo_pr = "#" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				tasks = tostring(pr.tasks_count or 0),
				status = state_label,
				status_raw = state_str,
				author = string.format("%s %s", icons.general("user"), author_display),
				author_hl = author_name,
				repo = string.format("%s %s", REPO_ICON, repo_label),
				repo_hl = repo_label,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = {
					kind = "pr",
					id = pr.id,
					repo = group.repo,
					pr = pr,
				},
			})
			table.insert(rows, {
				kind = "meta",
				pr_icon = "",
				repo_pr = src .. " → " .. dst,
				conversation = "",
				tasks = "",
				status = "",
				status_raw = "",
				author = "",
				repo = "",
				created = "",
				updated = "",
				separator = true,
				_item = {
					kind = "pr_meta",
					id = pr.id,
					repo = group.repo,
					pr = pr,
				},
			})
		end
	end
	return { columns = compact_columns(), rows = rows }
end

---@return table[]
local function plain_columns()
	return {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "name", name = "PR", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "tasks", name = TASKS_ICON, min_width = 2, can_grow = false, header_hl = "AtlasColumnHeader" },
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "branch",
			name = string.format("%s Branch", icons.pulls("branch")),
			max_width = 28,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	}
end

---@param groups PullsGroup[]|nil
---@return { columns: table, rows: table[] }
function M.build_plain_tree_table(groups)
	local rows = {}
	for i, group in ipairs(groups or {}) do
		local repo_label = group.repo.name or ""
		if i > 1 then
			table.insert(rows, {
				kind = "spacer",
				pr_icon = "",
				name = "",
				conversation = "",
				tasks = "",
				status = "",
				status_raw = "",
				author = "",
				branch = "",
				created = "",
				updated = "",
			})
		end
		table.insert(rows, {
			kind = "repo",
			pr_icon = REPO_ICON,
			name = repo_label,
			repo_full_name = repo_label,
			conversation = "",
			tasks = "",
			status = "",
			status_raw = "",
			author = "",
			branch = "",
			created = "",
			updated = "",
			separator = true,
			_item = { kind = "repo", repo = group.repo },
		})
		for _, pr in ipairs(group.prs or {}) do
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local author_name = (pr.author and pr.author.name) and pr.author.name or ""
			local src = (pr.source and pr.source.branch) or ""
			local dst = (pr.destination and pr.destination.branch) or ""
			local icon = pr_icon_or_spinner(pr)
			local _, icon_hl = pr_icon_and_hl(pr)
			local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
			local state_str = tostring(pr.state or "")
			local author_display = utils.shorten_name(author_name, 20)
			table.insert(rows, {
				kind = "pr",
				pr_icon = icon,
				_pr_reloading = is_reloading,
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = "#" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				tasks = tostring(pr.tasks_count or 0),
				status = "",
				status_raw = state_str,
				author = string.format("%s %s", icons.general("user"), author_display),
				author_hl = author_name,
				branch = utils.truncate(src .. " → " .. dst, 28),
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = group.repo, pr = pr },
			})
		end
	end
	return {
		columns = plain_columns(),
		rows = rows,
	}
end

local POPUP_MODULES = {
	github = "atlas.pulls.providers.github.ui.popup",
	gitlab = "atlas.pulls.providers.gitlab.ui.popup",
	bitbucket = "atlas.pulls.providers.bitbucket.ui.popup",
}

---@param pr PullRequest
---@return string[], table[]
function M.pr_popup_content(pr)
	local provider_id = state.provider and state.provider.id or nil
	local mod_path = provider_id and POPUP_MODULES[provider_id] or POPUP_MODULES.bitbucket
	local ok, mod = pcall(require, mod_path)
	if not ok or type(mod) ~= "table" or type(mod.content) ~= "function" then
		local fallback_ok, fallback = pcall(require, POPUP_MODULES.bitbucket)
		if fallback_ok and type(fallback) == "table" and type(fallback.content) == "function" then
			return fallback.content(pr)
		end
		return { "" }, {}
	end
	return mod.content(pr)
end

---@param pr PullRequest
---@return string[], table[]
local function github_pr_popup_content(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local id = tostring(pr.id or "")
	local title = tostring(pr.title or "")
	local author_name = tostring((pr.author and pr.author.name) or "Unknown")
	local repo_name = tostring(pr.repo_full_name or "")

	local state_str = tostring(pr.state or "-")
	if raw.isDraft == true then
		state_str = "draft"
	end

	local lines = { string.format(" #%s: %s", id, title), "" }
	---@type table[]
	local hl = {
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if id ~= "" then
		table.insert(hl, { row = 0, col = 2, end_col = 2 + #id, hl_group = "AtlasTextMuted" })
	end

	---@param label string
	---@param value string|nil
	---@param value_hl string|nil
	local function push(label, value, value_hl)
		if value == nil or value == "" then
			return
		end
		local row = #lines
		table.insert(lines, string.format(" %-10s %s", label .. ":", value))
		table.insert(hl, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		if value_hl then
			table.insert(hl, { row = row, col = 12, end_col = -1, hl_group = value_hl })
		end
	end

	push("State", state_str, M.pr_state_hl(state_str))
	push("Author", author_name, M.author_hl(author_name))
	push("Repo", repo_name ~= "" and repo_name or nil, M.repo_hl(repo_name))
	push(
		"Branch",
		string.format("%s → %s", tostring((pr.source or {}).branch or "?"), tostring((pr.destination or {}).branch or "?")),
		"AtlasTextMuted"
	)

	local additions = tonumber(raw.additions) or 0
	local deletions = tonumber(raw.deletions) or 0
	local changed = tonumber(raw.changedFiles)
	if changed or additions > 0 or deletions > 0 then
		local add_str = string.format("+%d", additions)
		local del_str = string.format("-%d", deletions)
		local prefix = changed and string.format("%s ", tostring(changed)) or ""
		local value = string.format("%s(%s, %s)", prefix, add_str, del_str)
		local row = #lines
		local line = string.format(" %-10s %s", "Files:", value)
		table.insert(lines, line)
		table.insert(hl, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		-- 12 == col where value starts (` Files:     ` = 1 + 10 + 1)
		local val_start = 12
		if prefix ~= "" then
			table.insert(hl, {
				row = row,
				col = val_start,
				end_col = val_start + #prefix,
				hl_group = "AtlasTextMuted",
			})
		end
		local add_col = val_start + #prefix + 1 -- skip '('
		local del_col = add_col + #add_str + 2 -- skip ", "
		table.insert(hl, { row = row, col = add_col, end_col = add_col + #add_str, hl_group = "AtlasTextPositive" })
		table.insert(hl, { row = row, col = del_col, end_col = del_col + #del_str, hl_group = "AtlasLogError" })
	end

	local decision = tostring(raw.reviewDecision or "")
	if decision == "" or decision == "REVIEW_REQUIRED" then
		-- reviewDecision is null on repos without enforced required-reviewers,
		-- so fall back to scanning the latest opinionated reviews.
		local approved, changes = 0, 0
		for _, n in ipairs((raw.latestOpinionatedReviews and raw.latestOpinionatedReviews.nodes) or {}) do
			local s = tostring(n.state or ""):upper()
			if s == "APPROVED" then approved = approved + 1
			elseif s == "CHANGES_REQUESTED" then changes = changes + 1
			end
		end
		if changes > 0 then
			decision = "CHANGES_REQUESTED"
		elseif approved > 0 then
			decision = "APPROVED"
		end
	end
	if decision ~= "" and decision ~= "REVIEW_REQUIRED" then
		local review_icon = decision == "APPROVED" and icons.pulls_status("successful")
			or decision == "CHANGES_REQUESTED" and icons.pulls_status("failed")
			or icons.pulls_status("inprogress")
		local decision_hl = decision == "APPROVED" and "AtlasTextPositive"
			or decision == "CHANGES_REQUESTED" and "AtlasTextWarning"
			or "AtlasTextMuted"
		push("Review", review_icon, decision_hl)
	end

	local rollup_ok, rollup_state = pcall(function()
		return raw.commits.nodes[1].commit.statusCheckRollup.state
	end)
	if rollup_ok and type(rollup_state) == "string" then
		local s = rollup_state:upper()
		local ci_icon = (s == "SUCCESS") and icons.pulls_status("successful")
			or (s == "FAILURE" or s == "ERROR") and icons.pulls_status("failed")
			or icons.pulls_status("inprogress")
		local ci_hl = (s == "SUCCESS") and "AtlasTextPositive"
			or (s == "FAILURE" or s == "ERROR") and "AtlasLogError"
			or "AtlasTextWarning"
		push("CI", ci_icon, ci_hl)
	end

	local reviewer_names = {}
	local seen_reviewer = {}
	for _, n in ipairs((raw.latestOpinionatedReviews and raw.latestOpinionatedReviews.nodes) or {}) do
		local login = type(n.author) == "table" and n.author.login or nil
		if type(login) == "string" and login ~= "" and not seen_reviewer[login] then
			seen_reviewer[login] = true
			table.insert(reviewer_names, "@" .. login)
		end
	end
	if #reviewer_names > 0 then
		push("Reviewers", table.concat(reviewer_names, ", "), "AtlasTextMuted")
	end

	local labels = raw.labels and raw.labels.nodes or nil
	if type(labels) == "table" and #labels > 0 then
		local names = {}
		for _, n in ipairs(labels) do
			table.insert(names, tostring(n.name or ""))
		end
		push("Labels", table.concat(names, ", "), "AtlasTextMuted")
	end

	local milestone = raw.milestone
	if type(milestone) == "table" and milestone.title then
		push("Milestone", tostring(milestone.title), "AtlasTextMuted")
	end

	local assignees = raw.assignees and raw.assignees.nodes or nil
	if type(assignees) == "table" and #assignees > 0 then
		local logins = {}
		for _, n in ipairs(assignees) do
			table.insert(logins, "@" .. tostring(n.login or ""))
		end
		push("Assignees", table.concat(logins, ", "), M.author_hl(tostring(assignees[1].login or "")))
	end

	push("Conversation", tostring(pr.comments_count or 0), "AtlasTextMuted")
	push("Updated", utils.relative_time(pr.updated_on), "AtlasTextMuted")

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, hl
end

---@param pr PullRequest
---@return string[], table[]
function M.pr_popup_content(pr)
	local state = require("atlas.pulls.state")
	local provider_id = state.provider and state.provider.id or ""
	if provider_id == "github" then
		return github_pr_popup_content(pr)
	end
	return generic_pr_popup_content(pr)
end

return M
