local icons = require("atlas.ui.shared.icons")
local config = require("atlas.config")
local diff_parser = require("atlas.core.git.diff_parser")
local provider_icon, provider_hl = icons.pulls_provider("bitbucket", "provider")

---@class BitbucketProvider : PullsProvider
local M = {
	id = "bitbucket",
	name = "Bitbucket",
	icon = provider_icon,
	hl_group = provider_hl,
	panel = require("atlas.pulls.providers.bitbucket.ui.panel"),
}

function M.setup()
	require("atlas.pulls.providers.bitbucket.highlights").setup()
end

---@param pr PullRequest
---@return string[], table[]
function M.pr_popup_content(pr)
	return require("atlas.pulls.providers.bitbucket.ui.popup").content(pr)
end

---@return AtlasBitbucketConfig|nil
local function bb_config()
	return config.options
			and config.options.pulls
			and config.options.pulls.providers
			and config.options.pulls.providers.bitbucket
		or nil
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local users_api = require("atlas.pulls.providers.bitbucket.api.users")
	return users_api.fetch_current_user(on_done)
end

---@param context AtlasPullsCommentCompletionContext
---@return AtlasMarkdownCompletionProvider|nil
function M.comment_completion(context)
	return require("atlas.pulls.providers.bitbucket.completion.author").build_completion(context)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	---@cast view AtlasBitbucketViewConfig
	local pullrequest_state = require("atlas.pulls.state")
	local active_statuses = {}

	for status, enabled in pairs(pullrequest_state.status_filters or {}) do
		if enabled then
			table.insert(active_statuses, status)
		end
	end
	if #active_statuses == 0 then
		active_statuses = { "OPEN" }
	end

	local workspaces, repos = {}, {}
	local seen_ws = {}
	for _, ref in ipairs(view.repos or {}) do
		local ws = tostring(ref.workspace or "")
		if ws ~= "" and not seen_ws[ws] then
			seen_ws[ws] = true
			table.insert(workspaces, ws)
		end
		local repo = tostring(ref.repo or "")
		if repo ~= "" then
			table.insert(repos, repo)
		end
	end
	local parts = {}
	if #workspaces > 0 then
		table.insert(parts, string.format("workspace:%s", table.concat(workspaces, ",")))
	end
	if #repos > 0 then
		table.insert(parts, string.format("repo:%s", table.concat(repos, ",")))
	end
	for _, s in ipairs(active_statuses) do
		table.insert(parts, string.format("is:%s", s:lower()))
	end
	pullrequest_state.last_search_query = table.concat(parts, " ")

	return pr_api.fetch_pullrequests(view.repos or {}, {
		force_load = opts.force_load == true,
		pagelen = opts.pagelen,
		statuses = active_statuses,
	}, function(groups, err)
		if type(view.filter) ~= "function" then
			on_done(groups, err)
			return
		end

		local ctx = {
			user = require("atlas.pulls.state").current_user,
		}
		local filtered = {}
		for _, group in ipairs(groups or {}) do
			local prs = {}
			for _, pr in ipairs(group.prs or {}) do
				local ok, keep = pcall(view.filter, pr, ctx)
				if ok and keep ~= false then
					table.insert(prs, pr)
				end
			end
			if #prs > 0 then
				table.insert(filtered, vim.tbl_extend("force", group, { prs = prs }))
			end
		end

		on_done(filtered, err)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return nil
function M.fetch_description(pr, _opts, on_done)
	vim.schedule(function()
		on_done(tostring(pr.description or ""), nil)
	end)
	return nil
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	local workspace = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")

	if workspace == "" or repo == "" then
		on_done(nil, "PR missing workspace/repo info")
		return nil
	end

	return pr_api.fetch_pullrequest(workspace, repo, pr.id, {
		force_load = opts.force_load == true,
	}, on_done)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	return repositories_api.fetch_detail(repo, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	local raw = repo._raw or {}
	local links = type(raw.links) == "table" and raw.links or {}
	local branches = type(links.branches) == "table" and links.branches or {}
	local branches_url = tostring(branches.href or "")
	return repositories_api.fetch_branches(branches_url, opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	local raw = repo._raw or {}
	local links = type(raw.links) == "table" and raw.links or {}
	local tags = type(links.tags) == "table" and links.tags or {}
	local tags_url = tostring(tags.href or "")
	return repositories_api.fetch_tags(tags_url, opts, on_done)
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_repo_branch(repo, branch, on_done)
	local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
	return repositories_api.delete_branch(repo, branch, on_done)
end

---@return AtlasBitbucketViewConfig[]
function M.views()
	local cfg = bb_config()
	local view_configs = cfg and cfg.views or {}
	---@type AtlasBitbucketViewConfig[]
	local out = {}

	for _, v in ipairs(view_configs) do
		table.insert(out, {
			name = v.name,
			key = v.key,

			layout = v.layout,
			repos = v.repos,
			filter = v.filter,
		})
	end

	if #out == 0 then
		table.insert(out, {
			name = "Pull Requests",
			key = "1",
			layout = "compact",
			repos = {},
		})
	end

	return out
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_reviewers(pr, opts, on_done)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_builds(pr, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_activity(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_diffstat(pr, opts, on_done)
end

---@param pr PullRequest
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.bitbucket.actions")
	local ctx = {
		pr = pr,
		source = source,
	}

	actions.open(ctx, function(result, _)
		if result == nil then
			on_done(nil)
			return
		end
		on_done({ changed_pr = result.changed_pr, message = result.message })
	end)
end

function M.search()
	local actions = require("atlas.pulls.providers.bitbucket.actions")
	actions.run("search", { source = "main" }, function() end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_commits(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_diff(pr, opts, on_done)
end

---@param pr PullRequest
---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(_pr, commit, opts, on_done)
	local statuses_url = tostring(commit.statuses_url or "")
	if statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_commit_status(statuses_url, opts, on_done)
end

---@param comment PullsComment
---@param files DiffFile[]|nil
local function attach_hunk(comment, files)
	if not comment.inline or not files then
		return
	end
	local side = comment.inline.to ~= nil and "new" or "old"
	local line = comment.inline.to or comment.inline.from
	if line == nil then
		return
	end

	local function find_hunk()
		for _, file in ipairs(files) do
			if file.path == comment.inline.path or file.old_path == comment.inline.path then
				for _, hunk in ipairs(file.hunks or {}) do
					local s = side == "old" and hunk.old_start or hunk.new_start
					local c = side == "old" and hunk.old_count or hunk.new_count
					if s and c and line >= s and line < s + c then
						return hunk
					end
				end
			end
		end
		return nil
	end

	local hunk = find_hunk()
	if hunk ~= nil then
		comment.inline_hunk = diff_parser.window_hunk(hunk, side, line, 4)
	end
end

---@param task table
---@return PullsComment
local function task_to_comment(task)
	local links = type(task.links) == "table" and task.links or {}
	local function href(link)
		return type(link) == "table" and tostring(link.href or "") or tostring(link or "")
	end
	return {
		id = task.id,
		parent_id = task.comment_id,
		author = task.creator,
		content_raw = tostring(task.content_raw or ""),
		created_on = tostring(task.created_on or ""),
		inline = nil,
		inline_hunk = nil,
		is_task = true,
		state = task.pending == true and "PENDING" or (tostring(task.state or "") == "RESOLVED" and "RESOLVED" or nil),
		url = href(links.self),
		html_url = href(links.html),
		_raw = task,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	opts = opts or {}
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")

	local handles = {}
	local cancelled = false
	local comments_result, tasks_result, diff_result
	local comments_err

	local function finish()
		if cancelled then
			return
		end
		if comments_result == nil or tasks_result == nil or diff_result == nil then
			return
		end

		local merged = {}
		for _, c in ipairs(comments_result) do
			attach_hunk(c, diff_result)
			table.insert(merged, c)
		end
		for _, task in ipairs(tasks_result) do
			table.insert(merged, task)
		end
		table.sort(merged, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
		on_done(merged, comments_err)
	end

	local h1 = comments_api.fetch_comments(pr, opts, function(cs, err)
		if err then
			comments_err = err
			comments_result = {}
		else
			comments_result = cs or {}
		end
		finish()
	end)
	if h1 then
		table.insert(handles, h1)
	end

	local h2 = M.fetch_tasks(pr, opts, function(tasks)
		tasks_result = tasks or {}
		finish()
	end)
	if h2 then
		table.insert(handles, h2)
	end

	-- Bitbucket does not include hunks in its comments API, so fetch the diff to attach them.
	local h3 = pr_api.fetch_diff(pr, { force_refresh = opts.force_refresh == true }, function(files, err)
		diff_result = err and {} or (files or {})
		finish()
	end)
	if h3 then
		table.insert(handles, h3)
	end

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					pcall(h.cancel)
				end
			end
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tasks(pr, opts, on_done)
	opts = opts or {}
	return require("atlas.pulls.providers.bitbucket.api.comments").fetch_tasks(
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		pr.id,
		{ force_refresh = opts.force_refresh == true },
		function(tasks, err)
			if err then
				on_done(nil, err)
				return
			end

			local result = {}
			for _, task in ipairs(tasks or {}) do
				table.insert(result, task_to_comment(task))
			end
			table.sort(result, function(a, b)
				return tostring(a.created_on or "") < tostring(b.created_on or "")
			end)
			on_done(result, nil)
		end
	)
end

---@param inline { path: string, side: "old"|"new"|nil, line: integer }|nil
---@return { from?: number, to?: number, path?: string }|nil
local function inline_to_bitbucket(inline)
	if inline == nil then
		return nil
	end
	local out = { path = inline.path }
	if inline.side == "old" then
		out.from = inline.line
	else
		out.to = inline.line
	end
	return out
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}
	if opts.is_task then
		return M.add_task(pr, content, opts.parent, on_done)
	end
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")

	local bb_opts = {
		inline = inline_to_bitbucket(opts.inline),
		pending = opts.pending == true or (opts.parent ~= nil and opts.parent.state == "PENDING"),
	}
	if opts.parent then
		return comments_api.reply_comment(pr, opts.parent.parent_id or opts.parent.id, content, bb_opts, on_done)
	end
	return comments_api.add_comment(pr, content, bb_opts, on_done)
end

---@param pr PullRequest
---@param content string
---@param parent PullsComment|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_task(pr, content, parent, on_done)
	return require("atlas.pulls.providers.bitbucket.api.comments").create_task(
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		pr.id,
		content,
		{
			comment_id = parent and parent.id or nil,
			pending = parent ~= nil and parent.state == "PENDING",
		},
		function(created, err)
			if err or not created then
				on_done(nil, err or "Bitbucket did not return the created task")
				return
			end
			on_done(task_to_comment(created), nil)
		end
	)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	return M.add_comment(pr, content, { parent = parent }, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	if comment.is_task then
		return M.edit_task(pr, comment, on_done)
	end
	return require("atlas.pulls.providers.bitbucket.api.comments").edit_comment(
		pr,
		comment.id,
		comment.content_raw,
		nil,
		on_done
	)
end

---@param _pr PullRequest
---@param task PullsComment
---@param on_done fun(task: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_task(_pr, task, on_done)
	local raw = task._raw or {}
	local task_url = tostring((raw.links or {}).self or "")
	if task_url == "" then
		vim.schedule(function()
			on_done(nil, "Missing task URL")
		end)
		return nil
	end

	return require("atlas.pulls.providers.bitbucket.api.comments").update_task(task_url, {
		content_raw = task.content_raw,
		state = task.state == "RESOLVED" and "RESOLVED" or "UNRESOLVED",
	}, function(updated, err)
		if err or not updated then
			on_done(nil, err or "Bitbucket did not return the updated task")
			return
		end
		on_done(task_to_comment(updated), nil)
	end)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	if target.is_task then
		return M.delete_task(pr, target, on_done)
	end
	return require("atlas.pulls.providers.bitbucket.api.comments").delete_comment(pr, target.id, on_done)
end

---@param _pr PullRequest
---@param task PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_task(_pr, task, on_done)
	local raw = task._raw or {}
	local task_url = tostring((raw.links or {}).self or "")
	if task_url == "" then
		vim.schedule(function()
			on_done(false, "Missing task URL")
		end)
		return nil
	end

	return require("atlas.pulls.providers.bitbucket.api.comments").delete_task(task_url, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local root_id = root.parent_id or root.id
	return require("atlas.pulls.providers.bitbucket.api.comments").set_thread_resolved(pr, root_id, resolved, on_done)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.create_pr(opts, on_done)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_default_reviewers(opts, on_done)
end

return M
