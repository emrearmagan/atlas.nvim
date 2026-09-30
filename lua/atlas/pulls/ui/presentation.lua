local M = {}

local highlights = require("atlas.ui.shared.highlights")

---@param name string|nil
---@return string
function M.author_hl(name)
	if name == nil then
		return "AtlasTextMuted"
	end
	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unknown" or lower == "none" then
		return "AtlasTextMuted"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param user { name: string?, nickname: string?, username: string? }|nil
---@return string
function M.user_handle(user)
	if user == nil then
		return "Unknown"
	end
	if user.nickname and user.nickname ~= "" then
		return user.nickname
	end
	if user.username and user.username ~= "" then
		return user.username
	end
	return (user.name and user.name ~= "") and user.name or "Unknown"
end

---@param repo string|nil
---@return string
function M.repo_hl(repo)
	if repo == nil then
		return "AtlasTextMuted"
	end
	local lower = vim.trim(repo):lower()
	if lower == "" or lower == "none" then
		return "AtlasTextMuted"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param pr_state string|nil
---@return string
function M.pr_state_hl(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "AtlasPROpenChip"
	end
	if lower == "merged" then
		return "AtlasPRMergedChip"
	end
	if lower == "declined" then
		return "AtlasPRDeclinedChip"
	end
	if lower == "draft" then
		return "AtlasPRDraftChip"
	end
	return "AtlasTextMuted"
end

local gitlab_merge_states = {
	mergeable = "successful",
	can_be_merged = "successful",
	conflict = "failed",
	cannot_be_merged = "failed",
	ci_must_pass = "failed",
	discussions_not_resolved = "failed",
	blocked_status = "failed",
	merge_request_blocked = "failed",
	need_rebase = "failed",
	requested_changes = "failed",
	status_checks_must_pass = "failed",
	security_policy_violations = "failed",
	jira_association_missing = "failed",
	policies_denied = "failed",
	draft_status = "stopped",
	not_open = "stopped",
}

---@param pr GitLabPullRequest
---@return string|nil
function M.gitlab_merge_status(pr)
	local status = tostring(pr.detailed_merge_status or pr.merge_status or ""):lower()
	if status ~= "" then
		return gitlab_merge_states[status] or "inprogress"
	end
end

---@param reviewers PullsReviewer[]|nil
---@return string|nil, string|nil
function M.review_progress(reviewers)
	local approved, changes_requested, total = 0, 0, 0
	for _, reviewer in ipairs(reviewers or {}) do
		total = total + 1
		if reviewer.decision == "approved" then
			approved = approved + 1
		elseif reviewer.decision == "changes_requested" then
			changes_requested = changes_requested + 1
		end
	end
	if total == 0 then
		return nil, nil
	end
	local kind = changes_requested > 0 and "failed" or (approved == total and "successful" or "inprogress")
	local label = changes_requested > 0 and "Changes requested" or string.format("%d/%d approved", approved, total)
	return kind, label
end

return M
