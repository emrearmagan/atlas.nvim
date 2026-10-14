local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local ui_utils = require("atlas.ui.shared.utils")
local utils = require("atlas.pulls.ui.layouts.utils")

local M = {}

local github_checks = {
	SUCCESS = "successful",
	FAILURE = "failed",
	ERROR = "failed",
	PENDING = "inprogress",
	EXPECTED = "inprogress",
}
local github_reviews = { APPROVED = "successful", CHANGES_REQUESTED = "failed" }
local azure_merge_states = {
	notSet = "unknown",
	queued = "inprogress",
	conflicts = "failed",
	succeeded = "successful",
	rejectedByPolicy = "failed",
	failure = "failed",
}

local function group_by_repo(pulls)
	local groups, by_repo = {}, {}

	for _, pr in ipairs(utils.starred_first(pulls)) do
		local group = by_repo[pr.repo_full_name]
		if group == nil then
			group = { repo = pr.repo, pulls = {} }
			by_repo[pr.repo_full_name] = group
			table.insert(groups, group)
		end

		table.insert(group.pulls, pr)
	end

	return groups
end

M.github = {
	reference = "#",
	columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("conversation"), min_width = 2, can_grow = false },
		{ key = "review", name = icons.get("success"), min_width = 1, can_grow = false },
		{ key = "ci", name = icons.get("tasks"), min_width = 1, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "diff", name = icons.get("changes"), min_width = 5, max_width = 15, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	},
	values = function(pr, opts)
		---@cast pr GitHubPullRequest
		local icon = utils.pull_icon(pr, opts)
		local review, review_hl = utils.status_icon(github_reviews[pr.review_decision])
		local ci, ci_hl = utils.status_icon(github_checks[(pr.check_status or ""):upper()])
		local diff, diff_hl = utils.diff_stats(pr.lines_added or 0, pr.lines_removed or 0)

		return {
			name = icon .. " " .. utils.title(pr, "#"),
			conversation = tostring(pr.comments_count),
			review = review,
			review_hl = review_hl,
			ci = ci,
			ci_hl = ci_hl,
			author = utils.author(pr),
			diff = diff,
			diff_hl = diff_hl,
			created = ui_utils.relative_time(pr.created_on),
			updated = ui_utils.relative_time(pr.updated_on),
		}
	end,
	highlights = function(row, column)
		if column.key == "ci" then
			return row.ci_hl
		elseif column.key == "review" then
			return row.review_hl
		elseif column.key == "diff" then
			return row.diff_hl
		end
	end,
}

M.gitlab = {
	reference = "!",
	columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "ci", name = icons.get("pipeline"), min_width = 1, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	},
	values = function(pr, opts)
		---@cast pr GitLabPullRequest
		local icon = utils.pull_icon(pr, opts)
		local status = presentation.gitlab_merge_status(pr)
		local ci, ci_hl = "", "AtlasTextMuted"
		if status then
			ci, ci_hl = icons.get(status, "status")
		end

		return {
			name = icon .. " " .. utils.title(pr, "!"),
			conversation = tostring(pr.comments_count),
			ci = ci,
			ci_hl = ci_hl,
			author = utils.author(pr),
			created = ui_utils.relative_time(pr.created_on),
			updated = ui_utils.relative_time(pr.updated_on),
		}
	end,
	highlights = function(row, column)
		if column.key == "ci" then
			return row.ci_hl
		end
	end,
}

M.bitbucket = {
	reference = "#",
	columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "tasks", name = icons.get("tasks"), min_width = 2, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "review", name = icons.get("success"), min_width = 1, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	},
	values = function(pr, opts)
		---@cast pr BitbucketPullRequest
		local icon = utils.pull_icon(pr, opts)
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
			name = icon .. " " .. utils.title(pr, "#"),
			conversation = tostring(pr.comments_count or 0),
			tasks = tostring(pr.tasks_count or 0),
			author = utils.author(pr),
			review = review,
			review_hl = review_hl,
			created = ui_utils.relative_time(pr.created_on),
			updated = ui_utils.relative_time(pr.updated_on),
		}
	end,
	highlights = function(row, column)
		if column.key == "review" then
			return row.review_hl
		end

		if (column.key == "conversation" or column.key == "tasks") and row[column.key] == "0" then
			return "AtlasTextMuted"
		end
	end,
}

M.azure = {
	reference = "!",
	columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "merge", name = icons.get("merge", "actions"), min_width = 1, can_grow = false },
		{ key = "review", name = icons.get("success"), min_width = 1, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
	},
	values = function(pr, opts)
		---@cast pr AzurePullRequest
		local icon = utils.pull_icon(pr, opts)
		local merge, merge_hl = icons.get(azure_merge_states[pr.merge_status] or "unknown", "status")
		local status
		for _, reviewer in ipairs(pr.reviewers or {}) do
			if reviewer.decision == "changes_requested" then
				status = "failed"
				break
			elseif reviewer.decision == "approved" then
				status = "successful"
			end
		end
		local review, review_hl = utils.status_icon(status)

		return {
			name = icon .. " " .. utils.title(pr, "!"),
			merge = merge,
			merge_hl = merge_hl or "AtlasTextMuted",
			review = review,
			review_hl = review_hl or "AtlasTextMuted",
			author = utils.author(pr),
			created = ui_utils.relative_time(pr.created_on),
		}
	end,
	highlights = function(row, column)
		if column.key == "merge" then
			return row.merge_hl
		elseif column.key == "review" then
			return row.review_hl
		end
	end,
}

M.default = {
	reference = "#",
	columns = {
		{ key = "name", name = "Title", min_width = 42 },
		{ key = "conversation", name = icons.get("conversation"), min_width = 2, can_grow = false },
		{ key = "author", name = icons.get("user") .. " Author", min_width = 10, can_grow = false },
		{ key = "created", name = icons.get("created"), min_width = 4, can_grow = false },
		{ key = "updated", name = icons.get("updated"), min_width = 4, can_grow = false },
	},
	values = function(pr, opts)
		local icon = utils.pull_icon(pr, opts)

		return {
			name = icon .. " " .. utils.title(pr, "#"),
			conversation = tostring(pr.comments_count),
			author = utils.author(pr),
			created = ui_utils.relative_time(pr.created_on),
			updated = ui_utils.relative_time(pr.updated_on),
		}
	end,
}

---@param opts table
---@param pulls PullRequest[]
---@param provider table
---@return string[], table<integer, table>, table[]
function M.render(opts, pulls, provider)
	local rows = {}

	for _, group in ipairs(group_by_repo(pulls)) do
		if #rows > 0 then
			table.insert(rows, { kind = "spacer" })
		end

		table.insert(rows, { kind = "repo", name = group.repo.full_name, _item = { kind = "repo", repo = group.repo } })

		for _, pr in ipairs(group.pulls) do
			local row = provider.values(pr, opts)
			row.kind = "pr"
			row._item = { kind = "pr", id = pr.id, repo = pr.repo, pr = pr }

			table.insert(rows, { kind = "spacer" })
			table.insert(rows, row)
		end
	end

	return utils.render(opts, rows, provider.columns, provider.highlights, provider.reference)
end

return M
