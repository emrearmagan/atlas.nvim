local M = {}

local highlights = require("atlas.ui.shared.highlights")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.state")

local PR_ICON, PR_ICON_HL = icons.pulls("pr")
local MERGED_PR_ICON, MERGED_PR_ICON_HL = icons.pulls("merged_pr")
local DECLINED_PR_ICON, DECLINED_PR_ICON_HL = icons.pulls("declined_pr")
local REPO_ICON = icons.pulls("repo")
local TASKS_ICON = icons.pulls("tasks")
local STAR_ICON, STAR_ICON_HL = icons.general("star")

local PR_STATE_ICON = {
	open = { PR_ICON, PR_ICON_HL },
	draft = { PR_ICON, "AtlasPRDraft" },
	merged = { MERGED_PR_ICON, MERGED_PR_ICON_HL },
	declined = { DECLINED_PR_ICON, DECLINED_PR_ICON_HL },
}

---@param pr PullRequest
---@return string, string
local function pr_icon_and_hl(pr)
	local s = tostring(pr.state or ""):lower()
	local style = PR_STATE_ICON[s] or PR_STATE_ICON.open
	return style[1], style[2]
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
	if name == nil then
		return "AtlasTextMutedItalic"
	end
	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unknown" or lower == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param user { name: string?, nickname: string?, username: string? }|nil
---@return string
function M.user_handle(user)
	if user == nil then
		return "Unknown"
	end
	if user.nickname and user.nickname ~= "" then
		return user.nickname
	end
	if user.username and user.username ~= "" then
		return user.username
	end
	return (user.name and user.name ~= "") and user.name or "Unknown"
end

---@param repo string|nil
---@return string
function M.repo_hl(repo)
	if repo == nil then
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
	if col.key == "repo_pr" and ctx.text:find(STAR_ICON, 1, true) == 1 then
		return { { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_ICON_HL } }
	end
	if col.key == "name" and row.kind == "repo" then
		return { { start_col = 0, end_col = #ctx.text, hl_group = "AtlasSectionHeader" } }
	end
	if col.key == "name" and row.kind == "pr" then
		local is_reloading = row._pr_reloading == true
		local icon_hl = is_reloading and "AtlasTextMuted" or (row._pr_icon_hl or "AtlasPROpen")
		local pr_icon = row._pr_icon_str or PR_ICON
		local spans = {}
		if (ctx.text or ""):find(pr_icon .. " " .. STAR_ICON .. " ", 1, true) == 1 then
			table.insert(spans, {
				start_col = #pr_icon + 1,
				end_col = #pr_icon + 1 + #STAR_ICON,
				hl_group = STAR_ICON_HL,
			})
		end
		local icon_start = string.find(ctx.text or "", pr_icon, 1, true)
		if icon_start ~= nil then
			local start_col = icon_start - 1
			table.insert(spans, { start_col = start_col, end_col = start_col + #pr_icon, hl_group = icon_hl })
			return spans
		end
		local frame_len = #(state.reload_spinner_frame or "⠋")
		table.insert(spans, { start_col = 0, end_col = frame_len, hl_group = icon_hl })
		return spans
	end
	if col.key == "pr_icon" then
		local is_reloading = row.kind == "pr" and row._pr_reloading == true
		local hl_group = is_reloading and "AtlasTextMuted"
			or (row.kind == "pr" and (row._pr_icon_hl or "AtlasPROpen") or "AtlasTextMuted")
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "created" or col.key == "updated" or (row.kind == "meta" and col.key == "repo_pr") then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "author" then
		local hl_group = M.author_hl(row.author_hl or row.author)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	if col.key == "status" then
		local hl_group = M.status_badge_hl(row.status_raw)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end
	return nil
end

---@param pr PullRequest
---@return PullsRepo
function M.repo(pr)
	return {
		id = pr.repo_full_name,
		name = pr.repo_full_name,
		full_name = pr.repo_full_name,
		owner = pr.workspace,
		workspace = pr.workspace,
		repo_name = pr.repo,
	}
end

---@param pulls PullRequest[]
---@return { repo: PullsRepo, pulls: PullRequest[] }[]
function M.group_by_repo(pulls)
	local sections, by_repo = {}, {}
	for _, pr in ipairs(pulls) do
		local section = by_repo[pr.repo_full_name]
		if not section then
			section = { repo = M.repo(pr), pulls = {} }
			by_repo[pr.repo_full_name] = section
			table.insert(sections, section)
		end
		table.insert(section.pulls, pr)
	end
	return sections
end

---@param pulls PullRequest[]
---@return PullRequest[]
function M.starred_first(pulls)
	local starred, other = {}, {}
	for _, pr in ipairs(pulls) do
		table.insert(pr.is_starred and starred or other, pr)
	end
	return vim.list_extend(starred, other)
end

---@param pulls PullRequest[]
---@param current_user PullsUser|nil
---@return table[]
function M.build_statusline_items(pulls, current_user)
	local repo_names = {}
	local seen = {}
	for _, pr in ipairs(pulls) do
		local name = pr.repo_full_name
		if name ~= nil and name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(repo_names, name)
		end
	end
	local items = {
		{
			text = string.format("%s %d PR%s", PR_ICON, #pulls, #pulls == 1 and "" or "s"),
			hl_group = "AtlasFooterInfo",
		},
	}
	local user_name = tostring((current_user or {}).username or (current_user or {}).name or "")
	if user_name ~= "" then
		table.insert(items, {
			text = string.format("%s @%s", icons.general("user"), user_name),
			hl_group = "AtlasFooterText",
			priority = 50,
			min_width = 8,
		})
	end
	if #repo_names > 0 then
		table.insert(items, {
			text = string.format("%s %s", REPO_ICON, table.concat(repo_names, ", ")),
			hl_group = "AtlasFooterText",
			priority = 10,
			min_width = 8,
		})
	end
	return items
end

---@return table[]
local function compact_columns()
	local cols = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "repo_pr", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" },
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
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	})
	return cols
end

---@param pulls PullRequest[]
---@return { columns: table, rows: table[] }
function M.build_compact_table(pulls)
	local rows = {}
	for _, pr in ipairs(pulls) do
		local repo = M.repo(pr)
		local repo_label = repo.name
		local id_str = tostring(pr.id or "")
		local title = tostring(pr.title or "")
		local author_name = M.user_handle(pr.author)
		local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
		local state_str = tostring(pr.state or "")
		local state_label = state_str ~= "" and (" " .. state_str:sub(1, 1):upper() .. state_str:sub(2):lower() .. " ")
			or ""
		local author_display = utils.shorten_name(author_name, 20)
		local icon, icon_hl = pr_icon_and_hl(pr)
		table.insert(rows, {
			kind = "pr",
			pr_icon = pr_icon_or_spinner(pr),
			_pr_reloading = is_reloading,
			_pr_icon_str = icon,
			_pr_icon_hl = icon_hl,
			repo_pr = (pr.is_starred and STAR_ICON .. " " or "") .. "#" .. id_str .. " " .. title,
			conversation = tostring(pr.comments_count or 0),
			tasks = tostring(pr.tasks_count or 0),
			status = state_label,
			status_raw = state_str,
			author = string.format("%s %s", icons.general("user"), author_display),
			author_hl = author_name,
			created = utils.relative_time(pr.created_on),
			updated = utils.relative_time(pr.updated_on),
			_item = {
				kind = "pr",
				id = pr.id,
				repo = repo,
				pr = pr,
			},
		})
		table.insert(rows, {
			kind = "meta",
			pr_icon = "",
			repo_pr = repo_label,
			conversation = "",
			tasks = "",
			status = "",
			status_raw = "",
			author = "",
			created = "",
			updated = "",
			separator = true,
			_item = {
				kind = "pr_meta",
				id = pr.id,
				repo = repo,
				pr = pr,
			},
		})
	end
	return { columns = compact_columns(), rows = rows }
end

---@return table[]
local function list_columns()
	return {
		{ key = "name", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" },
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
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	}
end

---@param pulls PullRequest[]
---@param layout "grouped"|"plain"
---@return { columns: table, rows: table[] }
function M.build_list_table(pulls, layout)
	local rows = {}
	local grouped = layout == "grouped"
	local source = {}
	if grouped then
		source = M.group_by_repo(pulls)
	else
		for _, pr in ipairs(pulls) do
			table.insert(source, { repo = M.repo(pr), pulls = { pr } })
		end
	end
	for i, section in ipairs(source) do
		local repo_label = section.repo.name
		local section_pulls = section.pulls
		if grouped then
			if i > 1 then
				table.insert(rows, { kind = "spacer" })
			end
			table.insert(rows, {
				kind = "repo",
				name = repo_label,
				conversation = "",
				tasks = "",
				status = "",
				status_raw = "",
				author = "",
				created = "",
				updated = "",
				_item = { kind = "repo", repo = section.repo },
			})
			table.insert(rows, { kind = "spacer" })
		end
		for pr_index, pr in ipairs(section_pulls) do
			if not grouped and #rows > 0 then
				table.insert(rows, { kind = "spacer" })
			end
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local reference = (grouped and "" or pr.repo_full_name) .. "#" .. id_str
			local author_name = M.user_handle(pr.author)
			local icon = pr_icon_or_spinner(pr)
			local _, icon_hl = pr_icon_and_hl(pr)
			local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
			local state_str = tostring(pr.state or "")
			local author_display = utils.shorten_name(author_name, 20)
			table.insert(rows, {
				kind = "pr",
				_pr_reloading = is_reloading,
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = icon .. " " .. (pr.is_starred and STAR_ICON .. " " or "") .. reference .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				tasks = tostring(pr.tasks_count or 0),
				status = "",
				status_raw = state_str,
				author = string.format("%s %s", icons.general("user"), author_display),
				author_hl = author_name,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = section.repo, pr = pr },
			})
			if grouped and pr_index < #section_pulls then
				table.insert(rows, { kind = "spacer" })
			end
		end
	end
	return {
		columns = list_columns(),
		rows = rows,
	}
end

return M
