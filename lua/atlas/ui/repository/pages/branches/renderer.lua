local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param state RepositoryBranches
---@param width integer
---@return string[], table<integer, RepositoryBranchSelection>, table[]
function M.render(state, width)
	local rows = {}
	local branches = state.branches
	---@cast branches AtlasRepositoryBranches
	for _, branch in ipairs(branches.entries) do
		local row = {
			name = branch.name .. (branch.name == state.repo.default_branch and " (default)" or ""),
			message = (branch.message or ""):match("^[^\r\n]*"),
			hash = branch.hash:sub(1, 8),
			date = utils.format_date(branch.date),
			expanded = state.expanded == branch.name,
			_item = { branch = branch },
		}
		if state.root then
			row.children = {}
			local commits = row.expanded and state.commits or nil
			local message = "Expand to load commits"
			local hl_group = "AtlasTextMuted"
			if commits == "loading" then
				message = "Loading commits..."
				hl_group = "Normal"
			elseif type(commits) == "string" then
				message = commits
				hl_group = "AtlasLogError"
			elseif commits then
				message = "No commits found"
				for _, commit in ipairs(commits) do
					table.insert(row.children, {
						name = commit.hash:sub(1, 8),
						message = commit.message:match("^[^\r\n]*"),
						date = utils.format_date(commit.date),
						_item = { branch = branch, commit = commit },
					})
				end
			end
			if #row.children == 0 then
				table.insert(row.children, {
					name = message,
					_placeholder = hl_group,
					_item = {},
				})
			end
		end
		table.insert(rows, row)
	end

	local lines, line_map, spans = table_tree.render({
		columns = {
			{ key = "name", name = "Branch", can_grow = false, hl = "Normal" },
			{ key = "message", name = "Latest commit", hl = "AtlasTextMuted" },
			{ key = "hash", name = "Commit", can_grow = false, hl = "AtlasTextMuted" },
			{ key = "date", name = "Last commit", align = "right", header_align = "right", hl = "AtlasTextMuted" },
		},
		rows = rows,
		width = width - 1,
		margin = 0,
		show_header = false,
		tree = state.root and {
			column_key = "name",
			default_expanded = false,
			leaf_prefix = "│ ",
			leaf_hl = "AtlasTextMuted",
		} or nil,
		cell_hl = function(row)
			return row._placeholder
		end,
	})
	for line, entry in pairs(line_map) do
		if not entry.branch then
			line_map[line] = nil
		end
	end
	return lines, line_map, spans
end

---@param branch AtlasRepositoryBranch
---@param commit? RepositoryBranchCommit
---@return AtlasPickerPreview
function M.preview(branch, commit)
	local entry = commit or branch
	local lines = {
		"Branch: " .. branch.name,
		"Commit: " .. entry.hash,
		"Author: " .. (entry.author or ""),
		"Date: " .. (entry.date or ""),
	}
	if branch.protected then
		table.insert(lines, "Protected: Yes")
	end
	if entry.message and entry.message ~= "" then
		table.insert(lines, "")
		vim.list_extend(lines, utils.sanitize_lines(entry.message))
	end
	return { title = commit and branch.name .. " · " .. commit.hash:sub(1, 8) or branch.name, lines = lines }
end

return M
