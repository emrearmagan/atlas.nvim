local icons = require("atlas.ui.shared.icons")
local config = require("atlas.config")

---@class BitbucketProvider : PullsProvider
local M = {
	id = "bitbucket",
	name = "Bitbucket",
	icon = icons.pulls_provider("bitbucket", "provider"),
	hl_group = "AtlasBitbucketTheme",
	panel = require("atlas.pulls.providers.bitbucket.ui.panel"),
}

function M.setup()
	require("atlas.pulls.providers.bitbucket.highlights").setup()
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
function M.fetch_user(on_done)
	local users_api = require("atlas.pulls.providers.bitbucket.api.users")
	users_api.fetch_current_user(on_done)
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
function M.fetch_description(pr, opts, on_done)
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
	local raw = type(repo._raw) == "table" and repo._raw or {}
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
	local raw = type(repo._raw) == "table" and repo._raw or {}
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
function M.fetch_commit_status(pr, commit, opts, on_done)
	local statuses_url = tostring(commit.statuses_url or "")
	if statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	local pr_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
	return pr_api.fetch_commit_status(statuses_url, opts, on_done)
end

local HUNK_WINDOW = 4

---@param hunk DiffHunk
---@param side "new"|"old"
---@param line integer
---@return DiffHunk
local function window_around(hunk, side, line)
	local anchor_idx
	for i, dline in ipairs(hunk.lines or {}) do
		local ln = side == "old" and dline.old_line or dline.new_line
		if ln == line then
			anchor_idx = i
			break
		end
	end
	if anchor_idx == nil then
		return hunk
	end

	local first = math.max(1, anchor_idx - HUNK_WINDOW)
	local last = math.min(#hunk.lines, anchor_idx + HUNK_WINDOW)
	if first == 1 and last == #hunk.lines then
		return hunk
	end

	local new_lines = {}
	local additions, deletions = 0, 0
	local old_start_line, new_start_line
	for i = first, last do
		local d = hunk.lines[i]
		table.insert(new_lines, d)
		if d.kind == "add" then
			additions = additions + 1
		elseif d.kind == "remove" then
			deletions = deletions + 1
		end
		if old_start_line == nil and d.old_line ~= nil then
			old_start_line = d.old_line
		end
		if new_start_line == nil and d.new_line ~= nil then
			new_start_line = d.new_line
		end
	end

	local old_count, new_count = 0, 0
	for _, d in ipairs(new_lines) do
		if d.kind == "context" or d.kind == "remove" then
			old_count = old_count + 1
		end
		if d.kind == "context" or d.kind == "add" then
			new_count = new_count + 1
		end
	end

	return {
		header = hunk.header,
		context = hunk.context,
		old_start = old_start_line or hunk.old_start,
		old_count = old_count,
		new_start = new_start_line or hunk.new_start,
		new_count = new_count,
		additions = additions,
		deletions = deletions,
		lines = new_lines,
	}
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
			if file.path == comment.inline.path then
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
		comment.inline_hunk = window_around(hunk, side, line)
	end
end

---@param task table
---@return PullsComment
local function task_to_comment(task)
	return {
		id = task.id,
		parent_id = task.comment_id,
		author = task.creator and {
			name = task.creator.name,
			nickname = task.creator.nickname or task.creator.username,
			id = task.creator.id,
		} or nil,
		content_raw = tostring(task.content_raw or ""),
		created_on = tostring(task.created_on or ""),
		inline = nil,
		inline_hunk = nil,
		is_task = true,
		state = tostring(task.state or "") == "RESOLVED" and "RESOLVED" or nil,
		url = nil,
		html_url = nil,
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
	local first_err

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
		local task_entries = tasks_result.entries or tasks_result
		for _, t in ipairs(task_entries or {}) do
			table.insert(merged, task_to_comment(t))
		end
		table.sort(merged, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
		on_done(merged, first_err)
	end

	local h1 = comments_api.fetch_comments(pr, opts, function(cs, err)
		if err then
			first_err = first_err or err
			comments_result = {}
		else
			comments_result = cs or {}
		end
		finish()
	end)
	if h1 then
		table.insert(handles, h1)
	end

	local h2 = comments_api.fetch_tasks(
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		pr.id,
		{ force_refresh = opts.force_refresh == true },
		function(tasks, err)
			if err then
				first_err = first_err or err
				tasks_result = { entries = {} }
			else
				tasks_result = tasks or { entries = {} }
			end
			finish()
		end
	)
	if h2 then
		table.insert(handles, h2)
	end

	--- Bitbucket does not include the hunks in the comments API like GitHub does, so we need to fetch the diff to be able to attach the hunks later.
	local h3 = pr_api.fetch_diff(pr, { force_refresh = opts.force_refresh == true }, function(files, err)
		if err then
			first_err = first_err or err
			diff_result = {}
		else
			diff_result = files or {}
		end
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
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")

	if opts.is_task then
		return comments_api.create_task(
			tostring(pr.workspace or ""),
			tostring(pr.repo or ""),
			pr.id,
			content,
			{ comment_id = opts.parent and opts.parent.id or nil },
			function(created, err)
				if err or type(created) ~= "table" then
					on_done(nil, err)
					return
				end
				on_done(task_to_comment(created), nil)
			end
		)
	end

	local bb_opts = {
		parent_id = opts.parent and opts.parent.id or nil,
		inline = inline_to_bitbucket(opts.inline),
	}
	return comments_api.add_comment(pr, content, bb_opts, on_done)
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
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")

	if comment.is_task then
		local raw = type(comment._raw) == "table" and comment._raw or {}
		local task_url = tostring((raw.links or {}).self or "")
		if task_url == "" then
			vim.schedule(function()
				on_done(nil, "Missing task URL")
			end)
			return nil
		end
		return comments_api.update_task(task_url, {
			content_raw = comment.content_raw,
			state = comment.state == "RESOLVED" and "RESOLVED" or "UNRESOLVED",
		}, function(updated, err)
			if err or type(updated) ~= "table" then
				on_done(nil, err)
				return
			end
			on_done(task_to_comment(updated), nil)
		end)
	end

	return comments_api.edit_comment(pr, comment.id, comment.content_raw, nil, on_done)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")

	if target.is_task then
		local raw = type(target._raw) == "table" and target._raw or {}
		local task_url = tostring((raw.links or {}).self or "")
		if task_url == "" then
			vim.schedule(function()
				on_done(false, "Missing task URL")
			end)
			return nil
		end
		return comments_api.delete_task(task_url, function(_, err)
			on_done(err == nil, err)
		end)
	end

	return comments_api.delete_comment(pr, target.id, on_done)
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
