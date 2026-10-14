---@class ShortcutIssueRef : IssueRef
---@field workspace string|nil

---@class ShortcutIssueLabel : IssueLabel
---@field id integer

---@alias ShortcutStoryType "feature"|"bug"|"chore"

---@class ShortcutIssueTask
---@field id integer
---@field description string
---@field complete boolean
---@field position integer

---@class ShortcutIssue : Issue
---@field id integer
---@field type IssueType
---@field workflow_state_id integer
---@field owner_ids string[]
---@field follower_ids string[]
---@field labels ShortcutIssueLabel[]

---@class ShortcutIssueDetails : IssueDetails
---@field title string
---@field story_type ShortcutStoryType
---@field workflow_state_id integer
---@field tasks ShortcutIssueTask[]

local M = {}

local stories = require("atlas.issues.providers.shortcut.api.stories")
local comments = require("atlas.issues.providers.shortcut.api.comments")
local history = require("atlas.issues.providers.shortcut.api.history")
local config = require("atlas.config")
local mapper = require("atlas.issues.providers.shortcut.api.mapper")

local DEFAULT_VIEWS = {
	{ name = "Open", key = "1", layout = "plain", search = "!is:done !is:archived" },
	{ name = "Bugs", key = "2", layout = "plain", search = "type:bug !is:done !is:archived" },
}

---@param target AtlasTarget
---@return AtlasShortcutIssuesViewConfig
function M.view_for_target(target)
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
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(view, opts, on_done)
	local query = tostring(view.search or "")
	if query == "" then
		on_done({ items = {}, query = query }, "Missing Shortcut Story search query")
		return nil
	end
	return stories.search(query, opts, on_done)
end

---@param ref ShortcutIssueRef
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

	local fetch_opts = vim.tbl_extend("force", {}, opts or {}, { workspace = ref.workspace })
	return stories.get(story_id, fetch_opts, on_done)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	return comments.list(issue, opts, function(items, err)
		if err or items == nil then
			on_done(nil, err)
			return
		end

		local conversation = {}
		for _, comment in ipairs(items) do
			table.insert(conversation, {
				id = "comment:" .. comment.id,
				kind = "comment",
				created_at = comment.created_at,
				entity = comment,
			})
		end
		on_done(conversation, nil)
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

return {
	views = M.views,
	view_for_target = M.view_for_target,
	issue_ref = M.issue_ref,
	capabilities = {
		core = {
			fetch_issues = M.fetch_issues,
			fetch_by_refs = stories.fetch_by_refs,
			fetch_issue = M.fetch_issue,
			-- fetch_links = nil,
		},
		comments = {
			fetch_activity = history.fetch,
			fetch_conversation = M.fetch_conversation,
			add_comment = comments.add_comment,
			edit_comment = comments.edit_comment,
			delete_comment = comments.delete_comment,
			reactions = {
				options = mapper.reactions,
				add = comments.add_reaction,
			},
		},
		actions = require("atlas.issues.providers.shortcut.actions.registry"),
		ui = {
			detail = require("atlas.issues.providers.shortcut.ui.detail"),
			-- repository = nil,
		},
	},
}
