local M = {}

local icons = require("atlas.ui.shared.icons")

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
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		vim.list_extend(result, after_author)
		table.insert(result, {
			key = "created",
			name = icons.general("created"),
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		table.insert(result, {
			key = "updated",
			name = icons.general("updated"),
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
		max_width = 15,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}

	return {
		reference = "#",
		columns = columns(icons.general("conversation"), { ci_column, review_column }, { diff_column }),
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
	local successful = { icons.pulls_status("successful") }
	local failed = { icons.pulls_status("failed") }
	local in_progress = { icons.pulls_status("inprogress") }
	local muted = { icons.pulls_status("inprogress"), "AtlasTextMuted" }
	local stopped = { icons.pulls_status("stopped") }
	local statuses = {
		mergeable = successful,
		checking = in_progress,
		unchecked = muted,
		ci_must_pass = failed,
		ci_still_running = in_progress,
		discussions_not_resolved = failed,
		draft_status = stopped,
		not_approved = in_progress,
		not_open = stopped,
		blocked_status = failed,
		merge_request_blocked = failed,
		conflict = failed,
		need_rebase = failed,
		preparing = in_progress,
		requested_changes = failed,
		status_checks_must_pass = failed,
		security_policy_violations = failed,
		jira_association_missing = failed,
		external_status_checks = in_progress,
		approvals_syncing = muted,
		commits_status = muted,
		policies_denied = failed,
	}
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
			local status = tostring(pr.detailed_merge_status or pr.merge_status or ""):lower()
			if status == "" then
				return { ci = "", ci_hl = "AtlasTextMuted" }
			end
			local icon = statuses[status] or muted
			return { ci = icon[1], ci_hl = icon[2] or "AtlasTextMuted" }
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
	local review_icons = {
		approved = { icons.pulls_status("successful") },
		changes_requested = { icons.pulls_status("failed") },
		pending = { icons.pulls_status("inprogress"), "AtlasTextMuted" },
	}
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
		columns = columns(icons.general("conversation"), { task_column, review_column }, {}),
		values = function(pr)
			---@cast pr BitbucketPullRequest
			local decision = "pending"
			for _, reviewer in ipairs(pr.reviewers or {}) do
				if reviewer.decision == "changes_requested" then
					decision = "changes_requested"
				elseif reviewer.decision == "approved" and decision == "pending" then
					decision = "approved"
				end
			end
			local review = review_icons[decision]
			return {
				tasks = tostring(pr.tasks_count or 0),
				review = review[1],
				review_hl = review[2] or "AtlasTextMuted",
			}
		end,
		highlight = function(row, col, ctx)
			if col.key == "review" then
				local empty = row.kind == "meta" or row.kind == "repo"
				local hl = empty and "" or (row.review_hl or "AtlasTextMuted")
				return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
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
	bitbucket = bitbucket,
	github = github,
	gitlab = gitlab,
}

---@param provider string|nil
---@return table
function M.get(provider)
	return (displays[provider] or default)()
end

return M
