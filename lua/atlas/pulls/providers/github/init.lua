local icons = require("atlas.ui.shared.icons")
local main_ui = require("atlas.pulls.providers.github.ui.main")

---@class GitHubProvider : PullsProvider
local M = {
	id = "github",
	name = "GitHub",
	icon = icons.pulls_provider("github", "provider"),
	hl_group = "AtlasGitHubTheme",
	render = main_ui.render,
	panel = require("atlas.pulls.providers.github.ui.panel"),
	repo_panel = require("atlas.pulls.providers.github.ui.repo_panel"),
}

function M.setup()
	require("atlas.pulls.providers.github.highlights").setup()
end

---@return AtlasGitHubConfig
local function github_config()
	local config = require("atlas.config")
	return ((config.options.pulls or {}).providers or {}).github or {}
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local users_api = require("atlas.pulls.providers.github.api.users")
	local state = require("atlas.pulls.providers.github.state")

	users_api.fetch_user(function(user, err)
		if user then
			state.current_user = user
		end
		on_done(user, err)
	end)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local pr_api = require("atlas.pulls.providers.github.api.pullrequests")
	local gh_state = require("atlas.pulls.providers.github.state")
	---@cast view AtlasGitHubViewConfig

	local search = view.search or ""
	if search == "" then
		vim.schedule(function()
			on_done({}, { "No search query configured for view" })
		end)
		return nil
	end

	local query = search
	if not query:find("is:pr") then
		query = "is:pr " .. query
	end

	local pulls_state = require("atlas.pulls.state")
	local f = pulls_state.status_filters or {}
	local open, merged, declined = f.OPEN, f.MERGED, f.DECLINED
	if open and not merged and not declined then
		query = query .. " is:open"
	elseif merged and not open and not declined then
		query = query .. " is:merged"
	elseif declined and not open and not merged then
		query = query .. " is:closed -is:merged"
	elseif merged and declined and not open then
		query = query .. " is:closed"
	end

	gh_state.last_search_query = query

	return pr_api.search_prs(query, on_done, {
		force_load = opts.force_load == true,
		limit = opts.pagelen,
	})
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local pr_api = require("atlas.pulls.providers.github.api.pullrequests")

	local owner = pr.workspace or ""
	local repo = pr.repo or ""
	local number = pr.id

	if owner == "" or repo == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	return pr_api.get_pr(owner, repo, number, on_done, {
		force_load = opts.force_load == true,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:desc:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"body",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch description")
			return
		end

		local body = tostring(result.body or "")
		cli.set_cache(cache_key, body)
		on_done(body, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:reviewers:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"latestReviews,reviewRequests",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch reviewers")
			return
		end

		local reviewers = {}
		for _, review in ipairs(result.latestReviews or {}) do
			local login = type(review.author) == "table" and tostring(review.author.login or "") or ""
			if login ~= "" then
				local gh_state = tostring(review.state or ""):upper()
				local decision = "pending"
				if gh_state == "APPROVED" then
					decision = "approved"
				elseif gh_state == "CHANGES_REQUESTED" then
					decision = "changes_requested"
				end
				table.insert(reviewers, { name = login, nickname = login, decision = decision })
			end
		end

		for _, req in ipairs(result.reviewRequests or {}) do
			local login = type(req) == "table" and tostring(req.login or "") or ""
			if login ~= "" then
				local already = false
				for _, r in ipairs(reviewers) do
					if r.name == login then
						already = true
						break
					end
				end
				if not already then
					table.insert(reviewers, { name = login, nickname = login, decision = "pending" })
				end
			end
		end

		cli.set_cache(cache_key, reviewers)
		on_done(reviewers, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").get_builds(pr, on_done)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_merge_checks(pr, _opts, on_done)
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
	return pullrequests.get_merge_checks(pr, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end

		local checks = {}

		local rd = tostring(result.review_decision or "")
		if rd == "APPROVED" then
			table.insert(checks, {
				key = "reviews",
				state = "successful",
				label = "Reviews",
				details = { "All required reviewers have approved." },
			})
		elseif rd == "CHANGES_REQUESTED" then
			table.insert(checks, {
				key = "reviews",
				state = "failed",
				label = "Reviews",
				details = { "A reviewer has requested changes." },
			})
		elseif rd == "REVIEW_REQUIRED" then
			table.insert(checks, {
				key = "reviews",
				state = "warning",
				label = "Reviews",
				details = { "At least one approving review is required." },
			})
		else
			table.insert(checks, {
				key = "reviews",
				state = "muted",
				label = "Reviews",
				details = { "No review required" },
			})
		end

		local mergeable = tostring(result.mergeable or "")
		if mergeable == "MERGEABLE" then
			table.insert(checks, {
				key = "conflicts",
				state = "successful",
				label = "No conflicts with base branch",
				details = { "Changes can be cleanly merged." },
			})
		elseif mergeable == "CONFLICTING" then
			table.insert(checks, {
				key = "conflicts",
				state = "failed",
				label = "This branch has conflicts that must be resolved",
				details = { "Conflicting files must be resolved before merging." },
			})
		end

		on_done(checks, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	return require("atlas.pulls.providers.github.api.pullrequests").get_diffstat(pr, opts, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:activity:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh(
		{ "api", string.format("repos/%s/issues/%s/timeline", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch activity")
				return
			end

			local entries = {}
			for _, item in ipairs(result) do
				local event = tostring(item.event or "")
				local actor_login = (type(item.actor) == "table" and tostring(item.actor.login or ""))
					or (type(item.user) == "table" and tostring(item.user.login or ""))
					or ""
				local date = tostring(item.created_at or item.submitted_at or "")

				if event == "commented" then
					table.insert(entries, {
						kind = "comment",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = tostring(item.body or ""),
					})
				elseif event == "reviewed" then
					local state_label = tostring(item.state or ""):lower()
					local kind = state_label == "approved" and "approval"
						or state_label == "changes_requested" and "changes_requested"
						or "update"
					table.insert(entries, {
						kind = kind,
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
					})
				elseif event == "closed" or event == "merged" or event == "reopened" then
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = event,
					})
				elseif event == "head_ref_force_pushed" then
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = "force pushed",
					})
				elseif event == "committed" then
					local author = type(item.author) == "table" and item.author or {}
					local author_name = tostring(author.name or "")
					local msg = tostring(item.message or ""):match("([^\n]+)") or ""
					local sha = tostring(item.sha or ""):sub(1, 8)
					table.insert(entries, {
						kind = "update",
						actor = author_name ~= ""
								and { name = author_name, id = "", username = author_name, nickname = author_name }
							or nil,
						date = tostring(author.date or date),
						content_raw = sha ~= "" and string.format("%s %s", sha, msg) or msg,
					})
				elseif event == "base_ref_force_pushed" then
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = "base branch force pushed",
					})
				elseif event == "labeled" then
					local label = type(item.label) == "table" and tostring(item.label.name or "") or ""
					if label ~= "" then
						table.insert(entries, {
							kind = "update",
							actor = actor_login ~= ""
									and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
								or nil,
							date = date,
							content_raw = string.format("added label: %s", label),
						})
					end
				elseif event == "assigned" then
					local assignee = type(item.assignee) == "table" and tostring(item.assignee.login or "") or ""
					if assignee ~= "" then
						table.insert(entries, {
							kind = "update",
							actor = actor_login ~= ""
									and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
								or nil,
							date = date,
							content_raw = string.format("assigned %s", assignee),
						})
					end
				elseif event == "review_requested" then
					local reviewer = type(item.requested_reviewer) == "table"
							and tostring(item.requested_reviewer.login or "")
						or ""
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = reviewer ~= "" and string.format("requested review from %s", reviewer)
							or "requested review",
					})
				elseif event == "ready_for_review" then
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = "marked as ready for review",
					})
				elseif event == "convert_to_draft" then
					table.insert(entries, {
						kind = "update",
						actor = actor_login ~= ""
								and { name = actor_login, id = "", username = actor_login, nickname = actor_login }
							or nil,
						date = date,
						content_raw = "marked as draft",
					})
				end
			end

			cli.set_cache(cache_key, entries)
			on_done(entries, nil)
		end
	)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:comments:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh(
		{ "api", string.format("repos/%s/issues/%s/comments", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch comments")
				return
			end

			local comments = {}
			for _, raw in ipairs(result) do
				local user = raw.user or {}
				local reactions = nil
				if type(raw.reactions) == "table" then
					reactions = {
						["+1"] = tonumber(raw.reactions["+1"]) or 0,
						["-1"] = tonumber(raw.reactions["-1"]) or 0,
						laugh = tonumber(raw.reactions.laugh) or 0,
						hooray = tonumber(raw.reactions.hooray) or 0,
						confused = tonumber(raw.reactions.confused) or 0,
						heart = tonumber(raw.reactions.heart) or 0,
						rocket = tonumber(raw.reactions.rocket) or 0,
						eyes = tonumber(raw.reactions.eyes) or 0,
					}
				end
				table.insert(comments, {
					id = raw.id,
					parent_id = nil,
					author = {
						name = tostring(user.login or ""),
						nickname = tostring(user.login or ""),
						id = tostring(user.id or ""),
					},
					content_raw = tostring(raw.body or ""),
					created_on = tostring(raw.created_at or ""),
					deleted = false,
					inline = nil,
					url = nil,
					html_url = tostring(raw.html_url or ""),
					reactions = reactions,
				})
			end

			cli.set_cache(cache_key, comments)
			on_done(comments, nil)
		end
	)
end

---@param pr PullRequest
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"POST",
		string.format("repos/%s/issues/%s/comments", repo_slug, tostring(pr.id)),
		{ body = content },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to create comment")
				return
			end
			local user = result.user or {}
			on_done({
				id = result.id,
				parent_id = nil,
				author = {
					name = tostring(user.login or ""),
					nickname = tostring(user.login or ""),
					id = tostring(user.id or ""),
				},
				content_raw = tostring(result.body or ""),
				created_on = tostring(result.created_at or ""),
				deleted = false,
				inline = nil,
				html_url = tostring(result.html_url or ""),
			}, nil)
		end
	)
end

---@param pr PullRequest
---@param _parent_id number|string
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, _parent_id, content, on_done)
	-- GitHub issue comments have no threading - reply is just a new comment
	return M.add_comment(pr, content, on_done)
end

---@param pr PullRequest
---@param comment_id number|string
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment_id, content, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"PATCH",
		string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment_id)),
		{ body = content },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to edit comment")
				return
			end
			local user = result.user or {}
			on_done({
				id = result.id,
				parent_id = nil,
				author = {
					name = tostring(user.login or ""),
					nickname = tostring(user.login or ""),
					id = tostring(user.id or ""),
				},
				content_raw = tostring(result.body or ""),
				created_on = tostring(result.created_at or ""),
				deleted = false,
				inline = nil,
				html_url = tostring(result.html_url or ""),
			}, nil)
		end
	)
end

---@param pr PullRequest
---@param comment_id number|string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment_id, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"DELETE",
		string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment_id)),
		nil,
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			on_done(true, nil)
		end
	)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:commits:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"commits",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch commits")
			return
		end

		local commits = {}
		for _, raw in ipairs(result.commits or {}) do
			local hash = tostring(raw.oid or "")
			local authors = raw.authors or {}
			local author_name = ""
			local author_login = ""
			if #authors > 0 then
				author_name = tostring(authors[1].name or authors[1].login or "")
				author_login = tostring(authors[1].login or "")
			end

			table.insert(commits, {
				hash = hash,
				short_hash = #hash > 7 and hash:sub(1, 7) or hash,
				message = tostring(raw.messageHeadline or raw.messageBody or ""),
				author_name = author_name,
				author_nickname = author_login,
				date = tostring(raw.authoredDate or raw.committedDate or ""),
				html_url = repo_slug ~= "" and string.format("https://github.com/%s/commit/%s", repo_slug, hash) or nil,
			})
		end

		cli.set_cache(cache_key, commits)
		on_done(commits, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: PullsDiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local repo_slug = pr.repo_full_name or ""

	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:diff:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"diff",
		tostring(pr.id),
		"--repo",
		repo_slug,
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local diff_text = tostring(result or "")
		local diff_parser = require("atlas.core.git.diff_parser")
		local files = diff_parser.parse(diff_text)

		cli.set_cache(cache_key, files)
		on_done(files, nil)
	end)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or repo.name or "")

	if owner == "" or repo_name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local slug = owner .. "/" .. repo_name
	local cache_key = string.format("github:repo_details:%s", slug)

	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"repo",
		"view",
		slug,
		"--json",
		"name,nameWithOwner,owner,description,defaultBranchRef,isPrivate,createdAt,diskUsage,url",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repo details")
			return
		end

		local owner_login = type(result.owner) == "table" and tostring(result.owner.login or "") or owner

		---@type PullsRepoDetails
		local details = {
			id = tostring(result.nameWithOwner or slug),
			name = tostring(result.name or repo_name),
			full_name = tostring(result.nameWithOwner or slug),
			owner = owner_login,
			repo_name = tostring(result.name or repo_name),
			html_url = tostring(result.url or ""),
			description = tostring(result.description or ""),
			size = tonumber(result.diskUsage) or nil,
			default_branch = type(result.defaultBranchRef) == "table" and tostring(result.defaultBranchRef.name or "")
				or nil,
			is_private = result.isPrivate == true,
			created_on = tostring(result.createdAt or ""),
			readme = nil,
			_raw = result,
		}

		-- Fetch README separately
		cli.gh({
			"api",
			string.format("repos/%s/readme", slug),
			"--header",
			"Accept: application/vnd.github.raw+json",
		}, function(readme_result, readme_err)
			if not readme_err and readme_result then
				details.readme = tostring(readme_result)
			end
			cli.set_cache(cache_key, details)
			on_done(details, nil)
		end)
	end)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local slug = tostring(repo.full_name or "")

	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:branches:%s", slug)

	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/branches?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch branches")
			return
		end

		local entries = {}
		for _, branch in ipairs(result) do
			local commit = type(branch.commit) == "table" and branch.commit or {}
			table.insert(entries, {
				name = tostring(branch.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local branches = { entries = entries }
		cli.set_cache(cache_key, branches)
		on_done(branches, nil)
	end)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	local cli = require("atlas.pulls.providers.github.api.cli")
	local slug = tostring(repo.full_name or "")

	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:tags:%s", slug)

	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/tags?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch tags")
			return
		end

		local entries = {}
		for _, tag in ipairs(result) do
			local commit = type(tag.commit) == "table" and tag.commit or {}
			table.insert(entries, {
				name = tostring(tag.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local tags = { entries = entries }
		cli.set_cache(cache_key, tags)
		on_done(tags, nil)
	end)
end

---@param pr PullRequest|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local actions = require("atlas.pulls.providers.github.actions")
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
	local actions = require("atlas.pulls.providers.github.actions")
	actions.run("search", { source = "main" }, function() end)
end

function M.views()
	local cfg = github_config()
	return cfg.views or {}
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_notifications(opts, on_done)
	local notifications = require("atlas.pulls.providers.github.api.notifications")
	local merged = vim.tbl_extend("force", { all = true, per_page = 100 }, opts or {})
	return notifications.fetch(merged, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_read(id, on_done)
	local notifications = require("atlas.pulls.providers.github.api.notifications")
	return notifications.mark_read(id, on_done)
end

---@param id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.mark_notification_done(id, on_done)
	local notifications = require("atlas.pulls.providers.github.api.notifications")
	return notifications.mark_done(id, on_done)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local pr_api = require("atlas.pulls.providers.github.api.pullrequests")
	return pr_api.create_pr(opts, on_done)
end

return M
