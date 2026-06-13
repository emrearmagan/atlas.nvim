local icons = require("atlas.ui.shared.icons")

---@class GiteaPullsProvider : PullsProvider
local M = {
	id = "gitea",
	name = "Gitea",
	icon = icons.pulls_provider("gitea", "provider"),
	hl_group = "AtlasGiteaTheme",
	panel = require("atlas.pulls.providers.gitea.ui.panel"),
	repo_panel = nil,
}

function M.setup()
	require("atlas.pulls.providers.gitea.highlights").setup()
end

---@return AtlasGiteaPullsConfig
local function gitea_config()
	local config = require("atlas.config")
	return ((config.options.pulls or {}).providers or {}).gitea or {}
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local cli = require("atlas.pulls.providers.gitea.api.cli")
	local mapper = require("atlas.pulls.providers.gitea.api.mapper")
	local state = require("atlas.pulls.providers.gitea.state")

	return cli.api("GET", "/user", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local user = mapper.to_user(result)
		if user then
			state.current_user = user
		end
		on_done(user, nil)
	end, {
		action = "Fetch current user",
	})
end

---@param view AtlasGiteaPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local pr_api = require("atlas.pulls.providers.gitea.api.pullrequests")
	---@cast view AtlasGiteaPullsViewConfig
	return pr_api.list_prs(view, {
		force_load = opts and opts.force_load == true,
		pagelen = opts and opts.pagelen,
	}, on_done)
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.gitea.api.pullrequests")
	return pr_api.get_pr(pr, {
		force_load = opts and opts.force_load == true,
	}, on_done)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	return require("atlas.pulls.providers.gitea.api.checks").get_builds(pr, nil, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	return require("atlas.pulls.providers.gitea.api.pullrequests").get_diffstat(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	return require("atlas.pulls.providers.gitea.api.commits").fetch_commits(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	return require("atlas.pulls.providers.gitea.api.comments").fetch_comments(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[], reaction_options: PullsReactionOption[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	local comments_api = require("atlas.pulls.providers.gitea.api.comments")

	return comments_api.fetch_general_comments(pr, opts, function(comments, err)
		if err then
			on_done(nil, err)
			return
		end

		-- Prepend the PR body as the first "comment" if we have a description
		local all_comments = {}
		local description = tostring(pr.description or "")
		if description ~= "" then
			local author = pr.author
			table.insert(all_comments, {
				id = "__body__",
				parent_id = nil,
				author = author and {
					name = author.name or author.username or "",
					nickname = author.nickname or author.username or "",
					id = author.id or "",
				} or nil,
				content_raw = description,
				created_on = pr.created_on or "",
			})
		end
		for _, c in ipairs(comments or {}) do
			table.insert(all_comments, c)
		end

		on_done({
			comments = all_comments,
			events = {},
			reaction_options = nil,
		}, nil)
	end)
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	return require("atlas.pulls.providers.gitea.api.comments").add_comment(pr, content, opts, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	return require("atlas.pulls.providers.gitea.api.comments").edit_comment(pr, comment, on_done)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	return require("atlas.pulls.providers.gitea.api.comments").delete_comment(pr, target, on_done)
end

---@param opts { force_load?: boolean }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.gitea.api.notifications")
	return notifications.fetch(vim.tbl_extend("force", { limit = 100 }, opts or {}), on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	return require("atlas.pulls.providers.gitea.api.notifications").mark_read(id, on_done)
end

---@param pr PullRequest|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.gitea.actions")
	actions.open({ pr = pr, source = source }, function(result, _)
		if result == nil then
			on_done(nil)
			return
		end
		on_done({ changed_pr = result.changed_pr, message = result.message })
	end)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	return require("atlas.pulls.providers.gitea.api.pullrequests").create_pr(opts, on_done)
end

---@return AtlasGiteaPullsViewConfig[]
function M.views()
	local cfg = gitea_config()
	if type(cfg.views) == "table" and #cfg.views > 0 then
		return cfg.views
	end
	return {
		{
			name = "Open",
			key = "1",
			filter = { state = "open" },
		},
		{
			name = "Merged",
			key = "2",
			filter = { state = "merged" },
		},
	}
end

return M
