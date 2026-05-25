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
	if raw.draft == true then
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

	local pipeline = type(raw.head_pipeline) == "table" and raw.head_pipeline
		or type(raw.pipeline) == "table" and raw.pipeline
		or nil
	if pipeline ~= nil then
		local p_state = tostring(pipeline.status or ""):lower()
		if p_state ~= "" then
			local p_icon, p_hl
			if p_state == "success" then
				p_icon, p_hl = icons.pulls_status("successful"), "AtlasTextPositive"
			elseif p_state == "failed" then
				p_icon, p_hl = icons.pulls_status("failed"), "AtlasLogError"
			elseif p_state == "canceled" or p_state == "skipped" then
				p_icon, p_hl = icons.pulls_status("stopped"), "AtlasTextMuted"
			else
				p_icon, p_hl = icons.pulls_status("inprogress"), "AtlasTextWarning"
			end
			table.insert(rows, { "CI", string.format("%s %s", p_icon, p_state), p_hl })
		end
	end

	local detailed = tostring(raw.detailed_merge_status or raw.merge_status or "")
	if detailed ~= "" then
		local readable = detailed:gsub("_", " ")
		local mhl = "AtlasTextMuted"
		if detailed == "mergeable" then
			mhl = "AtlasTextPositive"
		elseif
			detailed:find("conflict")
			or detailed:find("blocked")
			or detailed:find("must_pass")
			or detailed:find("policies_denied")
			or detailed == "need_rebase"
		then
			mhl = "AtlasLogError"
		elseif
			detailed == "not_approved"
			or detailed:find("running")
			or detailed == "checking"
			or detailed == "preparing"
		then
			mhl = "AtlasTextWarning"
		end
		table.insert(rows, { "Status", readable, mhl })
	end

	local reviewers = type(raw.reviewers) == "table" and raw.reviewers or {}
	if #reviewers > 0 then
		local names = {}
		for _, r in ipairs(reviewers) do
			local nick = tostring(r.username or r.name or "")
			if nick ~= "" then
				table.insert(names, "@" .. nick)
			end
		end
		if #names > 0 then
			table.insert(rows, { "Reviewers", table.concat(names, ", "), "AtlasTextMuted" })
		end
	end

	local assignees = type(raw.assignees) == "table" and raw.assignees or {}
	if #assignees > 0 then
		local names = {}
		for _, a in ipairs(assignees) do
			local nick = tostring(a.username or a.name or "")
			if nick ~= "" then
				table.insert(names, "@" .. nick)
			end
		end
		if #names > 0 then
			table.insert(rows, {
				"Assignees",
				table.concat(names, ", "),
				helper.author_hl(tostring(assignees[1].username or "")),
			})
		end
	end

	local labels = type(raw.labels) == "table" and raw.labels or {}
	if #labels > 0 then
		local names = {}
		for _, l in ipairs(labels) do
			if type(l) == "string" then
				table.insert(names, l)
			elseif type(l) == "table" and l.name then
				table.insert(names, tostring(l.name))
			end
		end
		if #names > 0 then
			local display
			if #names > 2 then
				display = string.format("%s, %s +%d more", names[1], names[2], #names - 2)
			else
				display = table.concat(names, ", ")
			end
			table.insert(rows, { "Labels", display, "AtlasTextMuted" })
		end
	end

	local milestone = raw.milestone
	if type(milestone) == "table" and milestone.title then
		table.insert(rows, { "Milestone", tostring(milestone.title), "AtlasTextMuted" })
	end

	table.insert(rows, { "Conversation", tostring(pr.comments_count or 0), "AtlasTextMuted" })
	table.insert(rows, { "Updated", utils.relative_time(pr.updated_on), "AtlasTextMuted" })

	-- Build lines + hl inline (no shared scaffolding).
	local lines = { string.format(" !%s: %s", id, title), "" }
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
