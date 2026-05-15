local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.pulls.ui.main.helper")

---@param pr PullRequest
---@return string[], table[]
function M.content(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local id = tostring(pr.id or "")
	local title = tostring(pr.title or "")
	local author_name = tostring((pr.author and pr.author.name) or "Unknown")
	local repo_name = tostring(pr.repo_full_name or "")

	local state_str = tostring(pr.state or "-")
	if raw.isDraft == true then
		state_str = "draft"
	end

	local rows = {}
	table.insert(rows, { "State", state_str, helper.pr_state_hl(state_str) })
	table.insert(rows, { "Author", author_name, helper.author_hl(author_name) })
	if repo_name ~= "" then
		table.insert(rows, { "Repo", repo_name, helper.repo_hl(repo_name) })
	end
	table.insert(rows, {
		"Branch",
		string.format(
			"%s → %s",
			tostring((pr.source or {}).branch or "?"),
			tostring((pr.destination or {}).branch or "?")
		),
		"AtlasTextMuted",
	})

	local additions = tonumber(raw.additions) or 0
	local deletions = tonumber(raw.deletions) or 0
	local changed = tonumber(raw.changedFiles)
	if changed or additions > 0 or deletions > 0 then
		local add_str = string.format("+%d", additions)
		local del_str = string.format("-%d", deletions)
		local prefix = changed and string.format("%s ", tostring(changed)) or ""
		table.insert(rows, {
			label = "Files",
			segments = {
				{ text = prefix, hl = prefix ~= "" and "AtlasTextMuted" or nil },
				{ text = "(" },
				{ text = add_str, hl = "AtlasTextPositive" },
				{ text = ", " },
				{ text = del_str, hl = "AtlasLogError" },
				{ text = ")" },
			},
		})
	end

	local decision = tostring(raw.reviewDecision or "")
	if decision == "" or decision == "REVIEW_REQUIRED" then
		local approved, changes = 0, 0
		for _, n in ipairs((raw.latestOpinionatedReviews and raw.latestOpinionatedReviews.nodes) or {}) do
			local s = tostring(n.state or ""):upper()
			if s == "APPROVED" then
				approved = approved + 1
			elseif s == "CHANGES_REQUESTED" then
				changes = changes + 1
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
		table.insert(rows, { "Review", review_icon, decision_hl })
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
		table.insert(rows, { "CI", ci_icon, ci_hl })
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
		table.insert(rows, { "Reviewers", table.concat(reviewer_names, ", "), "AtlasTextMuted" })
	end

	local labels = raw.labels and raw.labels.nodes or nil
	if type(labels) == "table" and #labels > 0 then
		local names = {}
		for _, n in ipairs(labels) do
			table.insert(names, tostring(n.name or ""))
		end
		table.insert(rows, { "Labels", table.concat(names, ", "), "AtlasTextMuted" })
	end

	local milestone = raw.milestone
	if type(milestone) == "table" and milestone.title then
		table.insert(rows, { "Milestone", tostring(milestone.title), "AtlasTextMuted" })
	end

	local assignees = raw.assignees and raw.assignees.nodes or nil
	if type(assignees) == "table" and #assignees > 0 then
		local logins = {}
		for _, n in ipairs(assignees) do
			table.insert(logins, "@" .. tostring(n.login or ""))
		end
		table.insert(rows, {
			"Assignees",
			table.concat(logins, ", "),
			helper.author_hl(tostring(assignees[1].login or "")),
		})
	end

	table.insert(rows, { "Conversation", tostring(pr.comments_count or 0), "AtlasTextMuted" })
	table.insert(rows, { "Updated", utils.relative_time(pr.updated_on), "AtlasTextMuted" })

	-- Build lines + hl inline (no shared scaffolding).
	local lines = { string.format(" #%s: %s", id, title), "" }
	---@type table[]
	local hl = {
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if id ~= "" then
		table.insert(hl, { row = 0, col = 2, end_col = 2 + #id, hl_group = "AtlasTextMuted" })
	end

	for _, r in ipairs(rows) do
		local label = r.label or r[1]
		if r.segments then
			local value_parts = {}
			for _, seg in ipairs(r.segments) do
				table.insert(value_parts, seg.text or seg[1] or "")
			end
			local value = table.concat(value_parts)
			if value ~= "" then
				local row = #lines
				table.insert(lines, string.format(" %-10s %s", label .. ":", value))
				table.insert(hl, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
				local cursor = 12
				for _, seg in ipairs(r.segments) do
					local text = seg.text or seg[1] or ""
					local seg_hl = seg.hl or seg[2]
					if seg_hl and text ~= "" then
						table.insert(hl, {
							row = row,
							col = cursor,
							end_col = cursor + #text,
							hl_group = seg_hl,
						})
					end
					cursor = cursor + #text
				end
			end
		else
			local value = r.value or r[2]
			local value_hl = r.value_hl or r[3]
			if value ~= nil and value ~= "" then
				local row = #lines
				table.insert(lines, string.format(" %-10s %s", label .. ":", value))
				table.insert(hl, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
				if value_hl then
					table.insert(hl, { row = row, col = 12, end_col = -1, hl_group = value_hl })
				end
			end
		end
	end

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, hl
end

return M
