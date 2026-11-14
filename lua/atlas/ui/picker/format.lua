local M = {}

local code_preview = require("atlas.ui.components.code_preview")
local icons = require("atlas.ui.shared.icons")
local markdown = require("atlas.formats.markdown")
local utils = require("atlas.ui.shared.utils")
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

---@param items { name: string, username: string|nil }[]|nil
---@return string
local function names(items)
	return table.concat(
		vim.tbl_map(function(item)
			return item.username ~= "" and item.username or item.name
		end, items or {}),
		", "
	)
end

---@param title string
---@param fields string[][]
---@param description string|nil
---@return string[]
local function preview_lines(title, fields, description)
	local lines = { "# " .. title, "" }
	for _, field in ipairs(fields) do
		if field[2] and field[2] ~= "" then
			lines[#lines + 1] = string.format("**%s:** %s", field[1], field[2])
		end
	end

	if description then
		description = vim.trim((description:gsub("[%z\1-\8\11\12\14-\31\127]", "")))
		vim.list_extend(lines, { "", "## Description", "" })
		vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	end
	return lines
end

-- "lua/atlas/core/requests.lua", 3 -> "<icon> requests.lua:3  lua/atlas/core" with the folder muted.
---@param path string
---@param line integer|nil
---@return string, AtlasPickerChunk[]
function M.file(path, line)
	local name = vim.fs.basename(path)
	local icon, icon_hl = icons.get("file")
	if has_devicons then
		local glyph, highlight = devicons.get_icon(name, nil, { default = true })
		icon, icon_hl = glyph or icon, highlight or icon_hl
	end

	icon = icon .. " "
	name = line and name .. ":" .. line or name
	local dir = vim.fs.dirname(path)
	dir = dir ~= "." and "  " .. dir or ""
	return icon .. name .. dir, { { icon, icon_hl }, { name, "Normal" }, { dir, "AtlasTextMuted" } }
end

---@param preview AtlasPickerPreview
---@param width integer
---@return AtlasPickerPreview
function M.markdown(preview, width)
	local content = markdown.parse(table.concat(preview.lines, "\n"), { width = width })
	return { title = preview.title, lines = content.lines, highlights = content.highlights }
end

---@param lines string[]
---@param path string
---@return AtlasPickerPreview
function M.code(lines, path)
	local ok, highlights = pcall(code_preview.syntax_highlights, lines, { file_path = path })
	return { title = path, lines = lines, highlights = ok and highlights or {} }
end

---@param issue Issue
---@param details IssueDetails|nil
---@param width integer
---@param opts? { provider: string|nil, fields: string[][]|nil }
---@return AtlasPickerPreview
function M.issue(issue, details, width, opts)
	opts = opts or {}
	local status, author, extra = issue.status, issue.reporter, {}
	if opts.provider == "jira" and details then
		---@cast details JiraIssueDetails
		status = details.status or status
		author = details.reporter or author
		extra[#extra + 1] = { "Priority", details.priority }
		for _, field in ipairs(details.custom_fields) do
			extra[#extra + 1] = { field.name, field.formatted }
		end
	end

	local fields = {
		{ "Status", status },
		{ "Author", names({ author }) },
		{ "Assignees", details and names(details.assignees) or names({ issue.assignee }) },
		{ "Labels", details and names(details.labels) },
		{ "Milestone", details and details.milestone and details.milestone.title },
	}
	vim.list_extend(fields, extra)
	vim.list_extend(fields, opts.fields or {})
	local lines = preview_lines(issue.title, fields, details and details.description)
	return M.markdown({ title = issue.key, lines = lines }, width)
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@param opts? { fields: string[][]|nil }
---@return AtlasPickerPreview
function M.pullrequest(pr, details, width, opts)
	opts = opts or {}
	local status = pr.state .. "   updated " .. utils.relative_time(pr.updated_on)
	if pr.provider == "github" then
		---@cast pr GitHubPullRequest
		if pr.lines_added and pr.lines_removed then
			status = status .. string.format("   +%d -%d", pr.lines_added, pr.lines_removed)
		end
	end

	local fields = {
		{ "Status", status },
		{ "Repository", pr.repo_full_name },
		{ "Author", names({ pr.author }) },
		{ "Branches", pr.source.branch .. " → " .. pr.destination.branch },
		{ "Reviewers", names(pr.reviewers) },
		{ "Assignees", details and names(details.assignees) },
		{ "Labels", details and names(details.labels) },
	}
	vim.list_extend(fields, opts.fields or {})
	local id = (pr.provider == "gitlab" and "!" or "#") .. pr.id
	local lines = preview_lines(pr.title, fields, details and details.description)
	return M.markdown({ title = id, lines = lines }, width)
end

return M
