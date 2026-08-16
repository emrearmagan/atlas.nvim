---@class ShortcutIssueUser : IssueUser
---@field mention_name string|nil

---@class ShortcutIssueRef : IssueRef
---@field workspace string|nil

---@class ShortcutIssue : Issue
---@field id integer
---@field type IssueType
---@field owner_count integer
---@field labels IssueLabel[]

---@class ShortcutIssueDetails : IssueDetails
---@field parent IssueRef|nil
---@field sub_issues IssueRef[]

local M = {}

local api = require("atlas.issues.providers.shortcut.api")
local author_completion = require("atlas.providers.shortcut.completion.author")
local config = require("atlas.config")

local DEFAULT_VIEWS = {
	{ name = "Open", key = "1", layout = "plain", search = "!is:done !is:archived" },
	{ name = "Bugs", key = "2", layout = "plain", search = "type:bug !is:done !is:archived" },
}

---@param view IssuesViewConfig
---@param _opts IssuesFetchOpts|nil
---@return string
function M.search_query(view, _opts)
	return tostring(view.search or "")
end

---@param target AtlasTarget
---@return AtlasShortcutIssuesViewConfig
function M.search_view(target)
	return {
		name = "Search",
		layout = "compact",
		search = "id:" .. tostring(target.number),
	}
end

---@param target AtlasTarget
---@return ShortcutIssueRef|nil
function M.issue_ref(target)
	if target.issue_key then
		return { key = target.issue_key, workspace = target.workspace }
	end
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	local query = M.search_query(view, opts)
	if query == "" then
		on_done({}, nil, true, "Missing Shortcut Story search query")
		return nil
	end
	return api.stories.search(query, opts, on_done)
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	return api.stories.fetch_by_refs(refs, opts, function(issues, err)
		if err or #refs ~= 1 or #issues ~= 1 then
			on_done(issues, err)
			return
		end

		---@cast refs ShortcutIssueRef[]
		local workspace = refs[1].workspace
		local issue_workspace = tostring(issues[1].url or ""):match("^https://app%.shortcut%.com/([^/]+)/story/")
		if workspace and issue_workspace ~= workspace then
			on_done({}, "Shortcut Story does not belong to workspace " .. workspace)
			return
		end
		on_done(issues, nil)
	end)
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	local key = tostring(ref.key)
	local story_id = key:match("^%d+$") and tonumber(key) or nil
	if story_id == nil or story_id < 1 then
		on_done(nil, "Invalid Shortcut Story key: " .. key)
		return nil
	end

	return api.stories.get(story_id, opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	return api.comments.list(issue, { force_load = opts and opts.force_refresh }, function(comments, err)
		if err or comments == nil then
			on_done(nil, err)
			return
		end

		local items = {}
		for _, comment in ipairs(comments) do
			table.insert(items, {
				id = "comment:" .. comment.id,
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		on_done(items, nil)
	end)
end

---@return AtlasShortcutIssuesViewConfig[]
function M.views()
	local options = config.domain_options("shortcut", "issues") or {}
	if options.views and #options.views > 0 then
		return options.views
	end
	return DEFAULT_VIEWS
end

function M.refresh()
	api.service.clear_cache()
end

return {
	views = M.views,
	search_view = M.search_view,
	issue_ref = M.issue_ref,
	capabilities = {
		-- TODO: Add capabilities
		core = {
			fetch_user = api.members.get_current,
			search_query = M.search_query,
			fetch_issues = M.fetch_issues,
			fetch_by_refs = M.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			-- update_description = M.update_description,
			refresh = M.refresh,
		},
		comments = {
			comment_completion = author_completion.for_issues,
			fetch_conversation = M.fetch_conversation,
			add_comment = api.comments.add_comment,
			reply_comment = api.comments.reply_comment,
			edit_comment = api.comments.edit_comment,
			delete_comment = api.comments.delete_comment,
			-- fetch_activity = M.fetch_activity,
		},
		-- notifications = require("atlas.issues.providers.shortcut.notifications"),
		-- actions = require("atlas.issues.providers.shortcut.actions"),
		ui = {
			setup = require("atlas.issues.providers.shortcut.highlights").setup,
			detail = require("atlas.issues.providers.shortcut.ui.detail"),
		},
	},
}
