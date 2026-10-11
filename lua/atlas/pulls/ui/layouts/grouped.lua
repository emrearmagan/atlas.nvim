local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local shared = require("atlas.pulls.ui.layouts.shared")

local M = {}

local STAR_ICON = icons.get("star")

local function diff_stats(additions, deletions)
	if additions + deletions == 0 then
		return "", {}
	end

	local added = "+" .. tostring(additions)
	local removed = "-" .. tostring(deletions)
	local text = added .. " " .. removed

	return text,
		{
			{ start_col = 0, end_col = #added, hl_group = "AtlasTextPositive" },
			{ start_col = #added + 1, end_col = #text, hl_group = "AtlasLogError" },
		}
end

local function group_by_repo(pulls)
	local groups, by_repo = {}, {}

	for _, pull in ipairs(shared.starred_first(pulls)) do
		local group = by_repo[pull.repo_full_name]
		if group == nil then
			group = { repo = pull.repo, pulls = {} }
			by_repo[pull.repo_full_name] = group
			table.insert(groups, group)
		end

		table.insert(group.pulls, pull)
	end

	return groups
end

local function render(opts, pulls, columns, values, highlights, reference)
	local rows = {}

	for group_index, group in ipairs(group_by_repo(pulls)) do
		if group_index > 1 then
			table.insert(rows, { kind = "spacer" })
		end

		table.insert(rows, {
			kind = "repo",
			name = group.repo.full_name,
			_item = { kind = "repo", repo = group.repo },
		})
		table.insert(rows, { kind = "spacer" })

		for pull_index, pull in ipairs(group.pulls) do
			local row = shared.pull_row(pull, group.repo, opts)
			row.name = row._pr_icon_str
				.. " "
				.. (pull.is_starred and STAR_ICON .. " " or "")
				.. reference
				.. tostring(pull.id)
				.. " "
				.. pull.title

			for key, value in pairs(values(pull)) do
				row[key] = value
			end

			table.insert(rows, row)

			if pull_index < #group.pulls then
				table.insert(rows, { kind = "spacer" })
			end
		end
	end

	return shared.render(opts, rows, columns, highlights, reference)
end

function M.github(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },

		{
			key = "conversation",
			name = icons.get("conversation"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "review",
			name = icons.get("success"),
			min_width = 1,
			can_grow = false,
		},

		{
			key = "ci",
			name = icons.get("tasks"),
			min_width = 1,
			can_grow = false,
		},

		{
			key = "author",
			name = string.format("%s Author", icons.get("user")),
			min_width = 10,
			can_grow = false,
		},

		{
			key = "diff",
			name = icons.get("changes"),
			min_width = 5,
			max_width = 15,
			can_grow = false,
		},

		{
			key = "created",
			name = icons.get("created"),
			min_width = 4,
			can_grow = false,
		},

		{
			key = "updated",
			name = icons.get("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local ci_icons = {
		SUCCESS = { icons.get("successful", "status") },
		FAILURE = { icons.get("failed", "status") },
		ERROR = { icons.get("failed", "status") },
		PENDING = { icons.get("inprogress", "status") },
		EXPECTED = { icons.get("inprogress", "status") },
	}

	local review_icons = {
		APPROVED = { icons.get("successful", "status") },
		CHANGES_REQUESTED = { icons.get("failed", "status") },
		REVIEW_REQUIRED = { icons.get("inprogress", "status"), "AtlasTextMuted" },
	}

	local function values(pull)
		---@cast pull GitHubPullRequest
		local ci = { icons.get("inprogress", "status"), "AtlasTextMuted" }

		if pull.check_status then
			ci = ci_icons[pull.check_status:upper()] or ci
		end

		local review = review_icons[pull.review_decision] or review_icons.REVIEW_REQUIRED
		local diff, diff_highlights = diff_stats(pull.lines_added or 0, pull.lines_removed or 0)

		return {
			ci = ci[1],
			ci_hl = ci[2],
			review = review[1],
			review_hl = review[2],
			diff = diff,
			diff_hl = diff_highlights,
		}
	end

	local function highlights(row, column, context)
		if column.key == "ci" then
			local empty = row.kind == "repo"
			local highlight = empty and "" or (row.ci_hl or "AtlasTextMuted")

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end

		if column.key == "review" then
			local empty = row.kind == "repo"
			local highlight = empty and "" or (row.review_hl or "AtlasTextMuted")

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end

		if column.key == "diff" then
			return row.diff_hl
		end
	end

	return render(opts, pulls, columns, values, highlights, "#")
end

function M.gitlab(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },

		{
			key = "conversation",
			name = icons.get("comment"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "ci",
			name = icons.get("pipeline"),
			min_width = 1,
			can_grow = false,
		},

		{
			key = "author",
			name = string.format("%s Author", icons.get("user")),
			min_width = 10,
			can_grow = false,
		},

		{
			key = "created",
			name = icons.get("created"),
			min_width = 4,
			can_grow = false,
		},

		{
			key = "updated",
			name = icons.get("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local function values(pull)
		---@cast pull GitLabPullRequest
		local status = presentation.gitlab_merge_status(pull)

		if not status then
			return { ci = "", ci_hl = "AtlasTextMuted" }
		end

		local icon, highlight = icons.get(status, "status")

		return { ci = icon, ci_hl = highlight }
	end

	local function highlights(row, column, context)
		if column.key == "ci" then
			local empty = row.kind == "repo"
			local highlight = empty and "" or (row.ci_hl or "AtlasTextMuted")

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end
	end

	return render(opts, pulls, columns, values, highlights, "!")
end

function M.bitbucket(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },

		{
			key = "conversation",
			name = icons.get("comment"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "tasks",
			name = icons.get("tasks"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "author",
			name = string.format("%s Author", icons.get("user")),
			min_width = 10,
			can_grow = false,
		},

		{
			key = "review",
			name = icons.get("success"),
			min_width = 1,
			can_grow = false,
		},

		{
			key = "created",
			name = icons.get("created"),
			min_width = 4,
			can_grow = false,
		},

		{
			key = "updated",
			name = icons.get("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local function approvals(reviewers)
		local approved, changes_requested = 0, 0

		for _, reviewer in ipairs(reviewers or {}) do
			if reviewer.decision == "approved" then
				approved = approved + 1
			elseif reviewer.decision == "changes_requested" then
				changes_requested = changes_requested + 1
			end
		end

		if changes_requested > 0 then
			return icons.get("failed", "status")
		elseif approved > 0 then
			-- The list response does not include the required approval count.
			return icons.get("successful", "status")
		end

		return icons.get("inprogress", "status"), "AtlasTextMuted"
	end

	local function values(pull)
		---@cast pull BitbucketPullRequest
		local review, review_highlight = approvals(pull.reviewers)

		return {
			conversation = tostring(pull.comments_count or 0),
			tasks = tostring(pull.tasks_count or 0),
			review = review,
			review_hl = review_highlight,
		}
	end

	local function highlights(row, column)
		if column.key == "review" then
			return row.review_hl
		end

		if (column.key == "conversation" or column.key == "tasks") and row[column.key] == "0" then
			return "AtlasTextMuted"
		end
	end

	return render(opts, pulls, columns, values, highlights, "#")
end

function M.default(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },

		{
			key = "conversation",
			name = icons.get("conversation"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "author",
			name = string.format("%s Author", icons.get("user")),
			min_width = 10,
			can_grow = false,
		},

		{
			key = "created",
			name = icons.get("created"),
			min_width = 4,
			can_grow = false,
		},

		{
			key = "updated",
			name = icons.get("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local function values()
		return {}
	end

	local function highlights()
		return nil
	end

	return render(opts, pulls, columns, values, highlights, "#")
end

return M
