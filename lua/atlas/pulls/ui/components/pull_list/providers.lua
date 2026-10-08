local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")

local M = {}

local function columns(conversation, before_author, after_author)
	local function build(title_key, compact)
		local result = {}
		if compact then
			table.insert(result, {
				key = "pr_icon",
				name = "",
				min_width = 1,
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			})
		end
		table.insert(result, { key = title_key, name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" })
		table.insert(result, {
			key = "conversation",
			name = conversation,
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		vim.list_extend(result, before_author)
		table.insert(result, {
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 10,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		vim.list_extend(result, after_author)
		table.insert(result, {
			key = "created",
			name = icons.general("created"),
			min_width = 4,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		table.insert(result, {
			key = "updated",
			name = icons.general("updated"),
			min_width = 4,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		return result
	end

	return {
		compact = build("repo_pr", true),
		list = build("name", false),
	}
end

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

local function github()
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
	local ci_column = {
		key = "ci",
		name = icons.pulls("tasks"),
		min_width = 1,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}
	local review_column = {
		key = "review",
		name = icons.general("success"),
		min_width = 1,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}
	local diff_column = {
		key = "diff",
		name = icons.pulls("changes"),
		min_width = 5,
		max_width = 15,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}

	return {
		reference = "#",
		columns = columns(icons.general("conversation"), { review_column, ci_column }, { diff_column }),
		values = function(pr)
			---@cast pr GitHubPullRequest
			local ci = { icons.pulls_status("inprogress"), "AtlasTextMuted" }
			if pr.check_status then
				ci = ci_icons[pr.check_status:upper()] or ci
			end
			local review = review_icons[tostring(pr.review_decision or "")] or review_icons.REVIEW_REQUIRED
			local diff, diff_hl = diff_stats(pr.lines_added or 0, pr.lines_removed or 0)
			return {
				ci = ci[1],
				ci_hl = ci[2] or "AtlasTextMuted",
				review = review[1],
				review_hl = review[2] or "AtlasTextMuted",
				diff = diff,
				diff_hl = diff_hl,
			}
		end,
		highlight = function(row, col, ctx)
			if col.key == "ci" then
				local empty = row.kind == "meta" or row.kind == "repo"
				local hl = empty and "" or (row.ci_hl or "AtlasTextMuted")
				return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
			end
			if col.key == "review" then
				local empty = row.kind == "meta" or row.kind == "repo"
				local hl = empty and "" or (row.review_hl or "AtlasTextMuted")
				return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
			end
			if col.key == "diff" and row.kind == "pr" then
				return row.diff_hl
			end
		end,
	}
end

local function gitlab()
	local ci_column = {
		key = "ci",
		name = icons.pulls("pipeline") or icons.pulls_status("inprogress"),
		min_width = 1,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}

	return {
		reference = "!",
		columns = columns(icons.general("comment"), { ci_column }, {}),
		values = function(pr)
			---@cast pr GitLabPullRequest
			local status = presentation.gitlab_merge_status(pr)
			if not status then
				return { ci = "", ci_hl = "AtlasTextMuted" }
			end
			local icon, hl = icons.pulls_status(status)
			return { ci = icon, ci_hl = hl }
		end,
		highlight = function(row, col, ctx)
			if col.key == "ci" then
				local empty = row.kind == "meta" or row.kind == "repo"
				local hl = empty and "" or (row.ci_hl or "AtlasTextMuted")
				return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
			end
		end,
	}
end

local function bitbucket()
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
		-- For now, any approval counts as success. The PR list doesn't give us the minimum;
		-- we'd need a separate merge-checks request for that, i think. At least could not find anything
		elseif approved > 0 then
			return icons.pulls_status("successful")
		end
		return icons.pulls_status("inprogress"), "AtlasTextMuted"
	end

	local task_column = {
		key = "tasks",
		name = icons.pulls("tasks"),
		min_width = 2,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}
	local review_column = {
		key = "review",
		name = icons.general("success"),
		min_width = 1,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}

	return {
		reference = "#",
		columns = columns(icons.general("comment"), { task_column }, { review_column }),
		values = function(pr)
			---@cast pr BitbucketPullRequest
			local review, review_hl = approvals(pr.reviewers)
			return {
				conversation = tostring(pr.comments_count or 0),
				tasks = tostring(pr.tasks_count or 0),
				review = review,
				review_hl = review_hl,
			}
		end,
		highlight = function(row, col)
			if row.kind == "pr" then
				if col.key == "review" then
					return row.review_hl
				elseif (col.key == "conversation" or col.key == "tasks") and row[col.key] == "0" then
					return "AtlasTextMuted"
				end
			end
		end,
	}
end

local function default()
	return {
		reference = "#",
		columns = columns(icons.general("conversation"), {}, {}),
		values = function()
			return {}
		end,
		highlight = function() end,
	}
end

local displays = {
	bitbucket = bitbucket(),
	github = github(),
	gitlab = gitlab(),
}
local fallback = default()

---@param provider string|nil
---@return table
function M.get(provider)
	return displays[provider] or fallback
end

return M
