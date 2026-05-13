local M = {}

---Turn a github timeline event kind + payload into a  label/content pair.
---@param ctx table  must have at least `.event` or `.field` for the kind
---@return string label, string|nil content
function M.format(ctx)
	ctx = ctx or {}
	local kind = ctx.event or ctx.field or ""

	if kind == "labeled" then
		return "added label", ctx.label_name
	elseif kind == "unlabeled" then
		return "removed label", ctx.label_name
	elseif kind == "assigned" then
		return "assigned", ctx.assignee_login
	elseif kind == "unassigned" then
		return "unassigned", ctx.assignee_login
	elseif kind == "milestoned" then
		return "added milestone", ctx.milestone_title
	elseif kind == "demilestoned" then
		return "removed milestone", ctx.milestone_title
	elseif kind == "renamed" then
		return "renamed", string.format("%s → %s", ctx.rename_from or "", ctx.rename_to or "")
	elseif kind == "closed" then
		return "closed", ctx.commit_id and ("commit " .. ctx.commit_id) or nil
	elseif kind == "reopened" then
		return "reopened", nil
	elseif kind == "locked" then
		return "locked conversation", nil
	elseif kind == "unlocked" then
		return "unlocked conversation", nil
	elseif kind == "pinned" then
		return "pinned this issue", nil
	elseif kind == "unpinned" then
		return "unpinned this issue", nil
	elseif kind == "ready_for_review" then
		return "marked as ready for review", nil
	elseif kind == "convert_to_draft" then
		return "marked as draft", nil
	elseif kind == "head_ref_force_pushed" then
		return "force pushed", nil
	elseif kind == "base_ref_force_pushed" then
		return "base branch force pushed", nil
	elseif kind == "cross-referenced" then
		return "referenced", ctx.source_title or ctx.source_url
	elseif kind == "referenced" then
		return "referenced", ctx.commit_id and ("commit " .. ctx.commit_id) or nil
	elseif kind == "transferred" then
		return "transferred", nil
	elseif kind == "marked_as_duplicate" then
		return "marked as duplicate", nil
	elseif kind == "connected" then
		return "linked a pull request", nil
	elseif kind == "disconnected" then
		return "unlinked a pull request", nil
	elseif kind == "subscribed" then
		return "subscribed", nil
	elseif kind == "unsubscribed" then
		return "unsubscribed", nil
	elseif kind == "mentioned" then
		return "was mentioned", nil
	elseif kind == "comment_deleted" then
		return "deleted a comment", nil
	elseif kind == "added_to_project_v2" then
		return "added to a project", nil
	elseif kind == "removed_from_project_v2" then
		return "removed from a project", nil
	elseif kind == "project_v2_item_status_changed" then
		return "changed project status", nil
	elseif kind == "blocking_added" then
		return "added a blocker", nil
	elseif kind == "blocking_removed" then
		return "removed a blocker", nil
	elseif kind == "review_requested" then
		return "requested a review", nil
	elseif kind == "reviewed" then
		return "reviewed", nil
	elseif kind == "committed" then
		return "added a commit", nil
	elseif kind == "parent_issue_added" then
		return "added a parent issue", nil
	elseif kind == "parent_issue_removed" then
		return "removed a parent issue", nil
	elseif kind == "sub_issue_added" then
		return "added a sub-issue", nil
	elseif kind == "sub_issue_removed" then
		return "removed a sub-issue", nil
	end
	return kind, nil
end

return M
