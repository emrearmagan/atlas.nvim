local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local utils = require("atlas.pulls.ui.layouts.utils")

local M = {}

local function render(opts, pulls, reference, columns, values, highlights)
	local rows = {}

	for _, pr in ipairs(utils.starred_first(pulls)) do
		if #rows > 0 then
			table.insert(rows, { kind = "spacer" })
		end

		local row = utils.pull_row(pr, opts, values)
		row.name = row._pr_icon_str .. " " .. utils.title(pr, reference)
		table.insert(rows, row)
	end

	return utils.render(opts, rows, columns, highlights, reference)
end

---@param opts table
---@param pulls GitHubPullRequest[]
---@return string[], table<integer, table>, table[]
function M.github(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("conversation"), min_width = 2, can_grow = false },
		{ key = "review", name = icons.get("success"), min_width = 1, can_grow = false },
		{ key = "ci", name = icons.get("tasks"), min_width = 1, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "diff", name = icons.get("changes"), min_width = 5, max_width = 15, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	}

	local checks = {
		SUCCESS = "successful",
		FAILURE = "failed",
		ERROR = "failed",
		PENDING = "inprogress",
		EXPECTED = "inprogress",
	}
	local reviews = { APPROVED = "successful", CHANGES_REQUESTED = "failed" }

	local function values(pr)
		---@cast pr GitHubPullRequest
		local ci, ci_hl = utils.status_icon(checks[(pr.check_status or ""):upper()])
		local review, review_hl = utils.status_icon(reviews[pr.review_decision])
		local diff, diff_hl = utils.diff_stats(pr.lines_added or 0, pr.lines_removed or 0)

		return { ci = ci, ci_hl = ci_hl, review = review, review_hl = review_hl, diff = diff, diff_hl = diff_hl }
	end

	local function highlights(row, column)
		if column.key == "ci" then
			return row.ci_hl
		elseif column.key == "review" then
			return row.review_hl
		elseif column.key == "diff" then
			return row.diff_hl
		end
	end

	return render(opts, pulls, "#", columns, values, highlights)
end

---@param opts table
---@param pulls GitLabPullRequest[]
---@return string[], table<integer, table>, table[]
function M.gitlab(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "ci", name = icons.get("pipeline"), min_width = 1, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	}

	local function values(pr)
		---@cast pr GitLabPullRequest
		local status = presentation.gitlab_merge_status(pr)
		if not status then
			return { ci = "", ci_hl = "AtlasTextMuted" }
		end

		local ci, ci_hl = icons.get(status, "status")
		return { ci = ci, ci_hl = ci_hl }
	end

	local function highlights(row, column)
		if column.key == "ci" then
			return row.ci_hl
		end
	end

	return render(opts, pulls, "!", columns, values, highlights)
end

---@param opts table
---@param pulls BitbucketPullRequest[]
---@return string[], table<integer, table>, table[]
function M.bitbucket(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "tasks", name = icons.get("tasks"), min_width = 2, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "review", name = icons.get("success"), min_width = 1, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	}

	local function values(pr)
		---@cast pr BitbucketPullRequest
		local status
		for _, reviewer in ipairs(pr.reviewers or {}) do
			if reviewer.decision == "changes_requested" then
				status = "failed"
				break
			elseif reviewer.decision == "approved" then
				-- The list response does not include the required approval count.
				status = "successful"
			end
		end

		local review, review_hl = utils.status_icon(status)
		return {
			conversation = tostring(pr.comments_count or 0),
			tasks = tostring(pr.tasks_count or 0),
			review = review,
			review_hl = review_hl,
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

	return render(opts, pulls, "#", columns, values, highlights)
end

---@param opts table
---@param pulls PullRequest[]
---@return string[], table<integer, table>, table[]
function M.default(opts, pulls)
	local columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("conversation"), min_width = 2, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	}

	return render(opts, pulls, "#", columns)
end

return M
