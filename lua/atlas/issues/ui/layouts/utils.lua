local presentation = require("atlas.issues.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param columns table[]
---@return table
function M.blank_row(columns)
	local row = {}
	for _, column in ipairs(columns) do
		row[column.key] = ""
	end

	return row
end

---@param rows table[]
---@param columns table[]
---@param spinner string|nil
function M.append_loading(rows, columns, spinner)
	local loading = M.blank_row(columns)
	loading.icon = spinner
	loading.name = "Loading..."

	table.insert(rows, M.blank_row(columns))
	table.insert(rows, loading)
end

---@param parts string[]
---@return string
function M.join(parts)
	local present = {}
	for _, part in ipairs(parts) do
		if part ~= "" then
			table.insert(present, part)
		end
	end

	return table.concat(present, "  ")
end

---@param spans table[]
---@param text string
---@param needle string
---@param hl_group string
---@return table[]
function M.highlight_match(spans, text, needle, hl_group)
	local start_col, end_col = text:find(needle, 1, true)
	if start_col and needle ~= "" then
		table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = hl_group })
	end

	return spans
end

---@param text string
---@param key string
---@param key_hl string
---@return table[]
function M.key_title_highlights(text, key, key_hl)
	local spans = M.highlight_match({}, text, key, key_hl)
	local key_end = spans[1] and spans[1].end_col
	if key_end and key_end + 1 < #text then
		table.insert(spans, { start_col = key_end + 1, end_col = #text, hl_group = "Normal" })
	end

	return spans
end

---@param user AtlasUser|nil
---@param fallback string
---@return string
function M.person_value(user, fallback)
	return icons.get("user") .. " " .. utils.shorten_name(user and user.name or fallback, 20)
end

---@param issue Issue
---@param key string
---@return string|nil
function M.person_hl(issue, key)
	if key == "assignee" or key == "reporter" then
		return presentation.person_hl(issue[key] and issue[key].name)
	end
end

---@param issue Issue
---@param opts { reloading?: table<string, boolean>, spinner?: string }
---@return string
function M.status_value(issue, opts)
	local reloading = opts.reloading and opts.reloading[issue.key]
	return " " .. (reloading and opts.spinner or issue.status or "") .. " "
end

---@param issue Issue
---@param opts { reloading?: table<string, boolean> }
---@param hl_group string
---@return string
function M.status_hl(issue, opts, hl_group)
	return opts.reloading and opts.reloading[issue.key] and "AtlasTextMuted" or hl_group
end

---@param status_id string|nil
---@return string
function M.state_chip_hl(status_id)
	return status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip"
end

---@param status_id string|nil
---@return string, string
function M.state_icon(status_id)
	if status_id == "closed" then
		return icons.get("successful", "status"), "AtlasIssueClosed"
	end

	return icons.get("issue"), "AtlasIssueOpen"
end

---@param issue Issue
---@return string, string
function M.type_icon(issue)
	local icon, hl_group = icons.get("issue")
	if issue.icon then
		return issue.icon.icon, issue.icon.hl_group or hl_group
	end

	return icon, hl_group
end

---@param issue Issue
---@return string
function M.due_text(issue)
	local due = utils.format_date(issue.duedate)
	return due ~= "" and (icons.get("created") .. " " .. due) or ""
end

return M
