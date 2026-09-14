---@class GitLabIssue : Issue
---@field project_path string
---@field iid integer

local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()
local actions = require("atlas.issues.providers.gitlab.actions")
local author_completion = require("atlas.providers.gitlab.completion.author")
local config = require("atlas.config")
local detail_ui = require("atlas.issues.providers.gitlab.ui.detail")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local notes_api = require("atlas.issues.providers.gitlab.api.notes")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local notifications_api = require("atlas.providers.gitlab.notifications")
local git = require("atlas.core.git")
local gitlab_query = require("atlas.providers.gitlab.query")

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local force_refresh = opts.force_refresh == true
	if tostring(issue.key or "") == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	return notes_api.list_conversation(issue, { force_refresh = force_refresh }, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, comment in ipairs(result.comments) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		for index, entry in ipairs(result.events) do
			table.insert(items, {
				id = table.concat({ "activity", entry.date or "", index }, ":"),
				kind = "activity",
				created_at = entry.date or "",
				entity = entry,
			})
		end
		on_done(items, nil)
	end)
end

---@return AtlasGitLabIssuesViewConfig[]
local function views()
	local cfg = config.domain_options("gitlab", "issues") or {}
	local configured = cfg.views
	if not configured or #configured == 0 then
		configured = {
			{ name = "Assigned", key = "1", scope = "assigned_to_me", state = "opened" },
			{ name = "Created", key = "2", scope = "created_by_me", state = "opened" },
		}
	end
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitlab" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].project = repo
			resolved[i].scope = view.scope or "all"
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
local function view_for_target(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
		state = "all",
	}
end

---@param target AtlasTarget
---@return IssueRef|nil
local function issue_ref(target)
	if target.project_path and target.number then
		return { key = string.format("%s#%d", target.project_path, target.number) }
	end
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = gitlab_query.issue_query,
	issue_ref = issue_ref,
	capabilities = {
		core = {
			fetch_user = users_api.get_user,
			fetch_issues = issues_api.list_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			update_description = issues_api.update_description,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = author_completion.for_issues,
			fetch_conversation = fetch_conversation,
			add_comment = notes_api.add_comment,
			reply_comment = notes_api.reply_comment,
			edit_comment = notes_api.edit_comment,
			delete_comment = notes_api.delete_comment,
			add_reaction = notes_api.add_reaction,
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			detail = detail_ui,
		},
	},
}
