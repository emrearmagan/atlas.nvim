local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local shared = require("atlas.pulls.ui.layouts.shared")

local M = {}

local STAR_ICON = icons.general("star")

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

local function render(opts, pulls, columns, values, highlights, reference)
	local rows = {}

	for _, pr in ipairs(shared.starred_first(pulls)) do
		local repo = pr.repo
		local row = shared.pull_row(pr, repo, opts)
		row.pr_icon = row._pr_icon_str
		row.repo_pr = (pr.is_starred and STAR_ICON .. " " or "") .. reference .. tostring(pr.id) .. " " .. pr.title

		for key, value in pairs(values(pr)) do
			row[key] = value
		end

		table.insert(rows, row)
		table.insert(rows, {
			kind = "meta",
			pr_icon = "",
			repo_pr = repo.full_name,
			separator = true,
			_item = { kind = "pr_meta", id = pr.id, repo = repo, pr = pr },
		})
	end

	return shared.render(opts, rows, columns, highlights, reference)
end

---@param opts table
---@param pulls GitHubPullRequest[]
---@return string[], table<integer, table>, table[]
function M.github(opts, pulls)
	local columns = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false },
		{ key = "repo_pr", name = "Title", min_width = 42 },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "review",
			name = icons.general("success"),
			min_width = 1,
			can_grow = false,
		},
		{
			key = "ci",
			name = icons.pulls("tasks"),
			min_width = 1,
			can_grow = false,
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 10,
			can_grow = false,
		},
		{
			key = "diff",
			name = icons.pulls("changes"),
			min_width = 5,
			max_width = 15,
			can_grow = false,
		},
		{
			key = "created",
			name = icons.general("created"),
			min_width = 4,
			can_grow = false,
		},
		{
			key = "updated",
			name = icons.general("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local ci_icons = {
		SUCCESS = { icons.pulls_status("successful") },
		FAILURE = { icons.pulls_status("failed") },
		ERROR = { icons.pulls_status("failed") },
		PENDING = { icons.pulls_status("inprogress") },
		EXPECTED = { icons.pulls_status("inprogress") },
	}

	local review_icons = {
		APPROVED = { icons.pulls_status("successful") },
		CHANGES_REQUESTED = { icons.pulls_status("failed") },
		REVIEW_REQUIRED = { icons.pulls_status("inprogress"), "AtlasTextMuted" },
	}

	local function values(pr)
		local ci = { icons.pulls_status("inprogress"), "AtlasTextMuted" }
		if pr.check_status then
			ci = ci_icons[pr.check_status:upper()] or ci
		end

		local review = review_icons[pr.review_decision] or review_icons.REVIEW_REQUIRED
		local diff, diff_highlights = diff_stats(pr.lines_added or 0, pr.lines_removed or 0)

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
			local empty = row.kind == "meta"
			local hl_group = empty and "" or (row.ci_hl or "AtlasTextMuted")
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end

		if column.key == "review" then
			local empty = row.kind == "meta"
			local hl_group = empty and "" or (row.review_hl or "AtlasTextMuted")
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end

		if column.key == "diff" then
			return row.diff_hl
		end
	end

	return render(opts, pulls, columns, values, highlights, "#")
end

---@param opts table
---@param pulls GitLabPullRequest[]
---@return string[], table<integer, table>, table[]
function M.gitlab(opts, pulls)
	local columns = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false },
		{ key = "repo_pr", name = "Title", min_width = 42 },
		{
			key = "conversation",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "ci",
			name = icons.pulls("pipeline"),
			min_width = 1,
			can_grow = false,
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 10,
			can_grow = false,
		},
		{
			key = "created",
			name = icons.general("created"),
			min_width = 4,
			can_grow = false,
		},
		{
			key = "updated",
			name = icons.general("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local function values(pr)
		local status = presentation.gitlab_merge_status(pr)
		if not status then
			return { ci = "", ci_hl = "AtlasTextMuted" }
		end

		local icon, hl_group = icons.pulls_status(status)
		return { ci = icon, ci_hl = hl_group }
	end

	local function highlights(row, column, context)
		if column.key == "ci" then
			local empty = row.kind == "meta"
			local hl_group = empty and "" or (row.ci_hl or "AtlasTextMuted")
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end
	end

	return render(opts, pulls, columns, values, highlights, "!")
end

---@param opts table
---@param pulls BitbucketPullRequest[]
---@return string[], table<integer, table>, table[]
function M.bitbucket(opts, pulls)
	local columns = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false },
		{ key = "repo_pr", name = "Title", min_width = 42 },
		{
			key = "conversation",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "tasks",
			name = icons.pulls("tasks"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 10,
			can_grow = false,
		},
		{
			key = "review",
			name = icons.general("success"),
			min_width = 1,
			can_grow = false,
		},
		{
			key = "created",
			name = icons.general("created"),
			min_width = 4,
			can_grow = false,
		},
		{
			key = "updated",
			name = icons.general("updated"),
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
			return icons.pulls_status("failed")
		elseif approved > 0 then
			-- The list API does not expose the minimum required approvals.
			return icons.pulls_status("successful")
		end

		return icons.pulls_status("inprogress"), "AtlasTextMuted"
	end

	local function values(pr)
		local review, review_highlight = approvals(pr.reviewers)

		return {
			conversation = tostring(pr.comments_count or 0),
			tasks = tostring(pr.tasks_count or 0),
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

---@param opts table
---@param pulls PullRequest[]
---@return string[], table<integer, table>, table[]
function M.default(opts, pulls)
	local columns = {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false },
		{ key = "repo_pr", name = "Title", min_width = 42 },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 10,
			can_grow = false,
		},
		{
			key = "created",
			name = icons.general("created"),
			min_width = 4,
			can_grow = false,
		},
		{
			key = "updated",
			name = icons.general("updated"),
			min_width = 4,
			can_grow = false,
		},
	}

	local function values()
		return {}
	end

	local function highlights() end

	return render(opts, pulls, columns, values, highlights, "#")
end

return M
