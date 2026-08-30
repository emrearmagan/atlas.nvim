local M = {}

local checkout = require("atlas.core.git.checkout")
local config = require("atlas.config")
local git = require("atlas.core.git")
local keymaps = require("atlas.core.keymaps")
local loading = require("atlas.pulls.diff.ui.loading")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.diff.notes")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local review_api = require("atlas.pulls.diff.review")
local session_api = require("atlas.pulls.diff.session")
local statusline = require("atlas.ui.statusline")

local ADAPTERS = {
	atlas = require("atlas.pulls.diff.atlas"),
	codediff = require("atlas.pulls.diff.codediff"),
	diffview = require("atlas.pulls.diff.diffview"),
}

local VIEWERS = {
	AtlasDiff = "atlas",
	CodeDiff = "codediff",
	DiffviewOpen = "diffview",
}

---@param operation string
---@param context table
---@param err string|nil
local function log_error(operation, context, err)
	if err then
		logger.logerror(operation .. " failed", vim.tbl_extend("force", {}, context, { error = tostring(err) }))
	end
end

---@class AtlasReviewOpenContext
---@field provider PullsProvider
---@field ref PullRequestRef
---@field current_user PullsUser|nil
---@field root string|nil

---@param requested AtlasPullsDiffOpenCommand|string|nil
---@return string|nil, string|nil
local function configured_command(requested)
	local diff = (config.options.pulls or {}).diff or {}
	local command = vim.trim(tostring(requested or diff.open_cmd or ""))
	if command == "" then
		return nil, "diff.open_cmd is not configured"
	end
	if vim.fn.exists(":" .. command) ~= 2 then
		return nil, string.format("diff.open_cmd command not found: %s", command)
	end
	return command, nil
end

-- Prefer an existing checkout; nil makes Atlas use its shared cache.
---@param context AtlasReviewOpenContext
---@param pr PullRequest
---@return string|nil
local function repository_path(context, pr)
	if context.root then
		return context.root
	end
	local cwd = vim.fn.getcwd()
	local current = git.local_repository(cwd)
	local current_repo = current and current.repo_full_name or nil
	local target = providers.resolve(pr.link.html)
	if
		current
		and current_repo
		and target
		and current.provider == target.provider
		and current.host:lower() == target.host:lower()
		and current_repo:lower() == pr.repo_full_name:lower()
	then
		return git.repo_root(cwd)
	end
	return checkout.resolve_repo_path_for_pr(pr, { require_git = true, require_existing = true })
end

---@param command string
---@param source AtlasDiffSource
---@return string|nil
local function open_external(command, source)
	if not source.head_revision then
		return "The configured diff viewer requires a base...head range"
	end
	local ok, err = pcall(vim.cmd, "tabnew")
	if not ok then
		return tostring(err)
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	ok, err = pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(source.root))
		vim.api.nvim_cmd({
			cmd = command,
			args = { source.base_revision .. "..." .. source.head_revision },
		}, {})
	end)
	if not ok and vim.api.nvim_tabpage_is_valid(tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tabpage) .. "tabclose")
	end
	return not ok and tostring(err) or nil
end

---@param session AtlasDiffSession
---@param view AtlasLoadingView
---@param warnings string[]
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }|nil
local function open_viewer(session, view, warnings, on_done)
	local viewer = ADAPTERS[session.viewer_id]
	return viewer.open(session, view, function(err)
		if not err and #warnings > 0 then
			session_api.notify(session, "warn", table.concat(warnings, "; "))
		end
		on_done(err)
	end)
end

---@param session AtlasDiffSession|nil
---@param viewer_id string
---@param source AtlasDiffSource
---@param review AtlasDiffReview|nil
---@param commits PullsCommit[]
---@return AtlasDiffSession
local function make_session(session, viewer_id, source, review, commits)
	if not session then
		return session_api.new({
			viewer_id = viewer_id,
			source = source,
			review = review,
			commits = commits,
		})
	end
	session.viewer_id = viewer_id
	if session.review_request then
		session.review_request.cancel()
		session.review_request = nil
	end
	session.source = source
	session.review = review
	session.commits = commits
	if review and review.context and review.context.reviewed_files then
		session.reviewed_files = review.context.reviewed_files
	end
	session.current = nil
	session.viewer_state = {}
	session.review_panel = nil
	session.statusline:dispose()
	local help_action = viewer_id == "atlas" and "ui.help" or "pulls.external_help"
	session.help_key = (keymaps.resolve(help_action) or {})[1]
	session.statusline = statusline.new({ help_key = session.help_key })
	session.closed = false
	session.note_target, session.notes = notes.load(review)
	return session
end

---@class AtlasDiffOpenOptions
---@field git_root string
---@field base_revision string
---@field head_revision string|nil
---@field open_cmd AtlasPullsDiffOpenCommand|string|nil

---@param opts AtlasDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@param target AtlasLoadingTarget|nil
---@param existing AtlasDiffSession|nil
---@return { cancel: fun() }|nil
local function start_range(opts, on_done, target, existing)
	local command, command_err = configured_command(opts.open_cmd)
	local root = vim.trim(opts.git_root)
	local base = vim.trim(opts.base_revision)
	local head = opts.head_revision and vim.trim(opts.head_revision) or nil
	if not command or root == "" or base == "" or head == "" then
		if on_done then
			on_done(command_err or "Repository path and base revision are required")
		end
		return nil
	end
	local operation = existing and "diff.reload" or "diff.open"
	local log = {
		viewer = VIEWERS[command] or command,
		root = root,
		base_revision = base,
		head_revision = head,
	}
	logger.loginfo(operation, log)

	local request = { cancel = function() end }
	local cancelled = false
	local function cancel()
		cancelled = true
		request.cancel()
	end
	local view = loading.open("Preparing diff...", cancel, target)

	local viewer_id = VIEWERS[command]
	if not viewer_id then
		local err = open_external(command, { root = root, base_revision = base, head_revision = head })
		view:finish()
		log_error(operation, log, err)
		if on_done then
			on_done(err)
		end
		return { cancel = cancel }
	end

	local session = make_session(existing, viewer_id, {
		root = root,
		base_revision = base,
		head_revision = head,
	}, nil, {})
	session.reload = function(next_target)
		start_range(opts, function(err)
			if err then
				notify.error("Unable to reload diff: " .. err, { vim_notify = true })
			end
		end, next_target, session)
	end
	request = open_viewer(session, view, {}, function(err)
		if cancelled then
			return
		end
		log_error(operation, log, err)
		if on_done then
			on_done(err)
		end
	end) or request
	return {
		cancel = function()
			cancel()
			view:finish()
		end,
	}
end

---@param context AtlasReviewOpenContext
---@param command string
---@param refresh boolean
---@param on_done fun(err: string|nil)|nil
---@param target AtlasLoadingTarget|nil
---@param existing AtlasDiffSession|nil
---@return { cancel: fun() }|nil
local function start_pr(context, command, refresh, on_done, target, existing)
	local viewer_id = VIEWERS[command]
	local operation = existing and "diff.reload" or "diff.open"
	local log = {
		viewer = viewer_id or command,
		provider = context.provider.id,
		repo = context.ref.repo_full_name,
		pr_id = context.ref.id,
	}
	logger.loginfo(operation, log)
	local request = { cancel = function() end }
	local cancelled = false
	local finished = false

	local function cancel()
		if cancelled or finished then
			return
		end
		cancelled = true
		request.cancel()
	end

	local view = loading.open("Preparing diff...", cancel, target)

	local function complete(err)
		if cancelled or finished then
			return
		end
		finished = true
		log_error(operation, log, err)
		if on_done then
			on_done(err)
		end
	end

	local function fail(err)
		view:finish()
		complete(err)
	end

	local function later(callback, ...)
		local count = select("#", ...)
		local args = { ... }
		vim.schedule(function()
			if not cancelled and not finished then
				callback(unpack(args, 1, count))
			end
		end)
	end

	---@param source AtlasDiffSource
	---@param review AtlasDiffReview|nil
	---@param commits PullsCommit[]
	---@param warnings string[]
	local function launch(source, review, commits, warnings)
		local session = make_session(existing, viewer_id, source, review, commits)
		session.reload = function(next_target)
			start_pr(context, command, true, function(err)
				if err then
					notify.error("Unable to reload diff: " .. err, { vim_notify = true })
				end
			end, next_target, session)
		end
		request = open_viewer(session, view, warnings, function(err)
			later(complete, err)
		end) or request
	end

	---@param pr PullRequest
	local function load_data(pr)
		local core = context.provider.capabilities.core
		local pending = request_scope.new()
		request = pending
		local starts = {}
		local repo_path = repository_path(context, pr)

		starts.repository = function(done)
			return checkout.ensure_pr_repository(pr, repo_path, function(message)
				view:update(message)
			end, function(root, err)
				if not root then
					pending.cancel()
					later(fail, tostring(err or "Unable to load pull request repository"))
					return
				end
				local base, head, revision_err = checkout.pr_diff_revisions(pr)
				if not base or not head then
					pending.cancel()
					later(fail, tostring(revision_err or "Unable to resolve pull request revisions"))
					return
				end
				done({ root = root, base_revision = base, head_revision = head }, nil)
			end)
		end

		if viewer_id then
			local review = existing and existing.review
				or {
					provider = context.provider,
					pr = pr,
					current_user = context.current_user,
					context = nil,
					data = {
						review = { pending = false },
						comments = {},
						tasks = {},
						reviewers = {},
						history = {},
					},
				}
			review.provider = context.provider
			review.pr = pr
			review.current_user = review.current_user or context.current_user
			starts.review = function(done)
				return review_api.load(review, refresh, function(loaded, warnings)
					done({ review = loaded, warnings = warnings }, nil)
				end)
			end
		end

		if viewer_id == "atlas" and core.fetch_commits then
			starts.commits = function(done)
				return core.fetch_commits(pr, { force_refresh = true }, done)
			end
		end

		view:update(refresh and "Refreshing diff data..." or "Loading diff data...")
		pending.all(starts, function(values, errors)
			later(function()
				local source = values.repository
				log.root = source.root
				log.base_revision = source.base_revision
				log.head_revision = source.head_revision

				if not viewer_id then
					local err = open_external(command, source)
					view:finish()
					complete(err)
					return
				end

				local review_result = values.review or { review = nil, warnings = {} }
				local warnings = review_result.warnings
				if errors.commits then
					warnings[#warnings + 1] = "Unable to load commits: " .. tostring(errors.commits)
				end
				launch(source, review_result.review, values.commits or {}, warnings)
			end)
		end)
	end

	view:update(refresh and "Refreshing pull request..." or "Loading pull request...")
	local core = context.provider.capabilities.core
	request = core.fetch_by_refs({ context.ref }, { force_refresh = refresh }, function(pulls, err)
		later(function()
			local pr = pulls and pulls[1] or nil
			if pr == nil then
				fail(tostring(err or "Unable to load pull request"))
				return
			end
			load_data(pr)
		end)
	end) or request
	return {
		cancel = function()
			cancel()
			view:finish()
		end,
	}
end

---@param value string
---@param requested AtlasPullsDiffOpenCommand|string|nil
---@return { cancel: fun() }|nil
function M.open_pull_request(value, requested)
	local target, target_err = providers.resolve(value)
	if not target then
		notify.error(target_err or "Invalid pull request URL", { vim_notify = true })
		return nil
	end
	if target.domain ~= "pulls" or target.entity ~= "pr" then
		notify.error("Expected a pull request URL", { vim_notify = true })
		return nil
	end
	if config.provider_options(target.provider) == nil then
		notify.error("Pull request provider is not configured: " .. target.provider, { vim_notify = true })
		return nil
	end
	local provider = providers.load(target.provider, target.domain)
	if not provider then
		notify.error("Unable to load pull request provider: " .. target.provider, { vim_notify = true })
		return nil
	end
	---@cast provider PullsProvider
	local command, command_err = configured_command(requested)
	if not command then
		notify.error(command_err, { vim_notify = true })
		return nil
	end
	local ref = target --[[@as PullRequestRef]]
	return start_pr(
		{
			provider = provider,
			ref = ref,
			current_user = nil,
		},
		command,
		true,
		function(err)
			if err then
				notify.error(err, { vim_notify = true })
			end
		end
	)
end

---@param opts AtlasDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@return { cancel: fun() }|nil
function M.open_range(opts, on_done)
	return start_range(opts, on_done)
end

---@param value string
function M.open_argument(value)
	if not value:find("...", 1, true) then
		M.open_pull_request(value, "AtlasDiff")
		return
	end
	local separator = value:find("...", 1, true)
	local base = vim.trim(value:sub(1, separator - 1))
	local head = vim.trim(value:sub(separator + 3))
	if base == "" or head == "" then
		notify.error("Expected an explicit base...head range", { vim_notify = true })
		return
	end
	local root, root_err = git.repo_root(vim.fn.getcwd())
	if not root then
		notify.error(root_err or "Unable to resolve repository root", { vim_notify = true })
		return
	end
	M.open_range({
		git_root = root,
		base_revision = base,
		head_revision = head,
		open_cmd = "AtlasDiff",
	}, function(err)
		if err then
			notify.error(err, { vim_notify = true })
		end
	end)
end

---@param context AtlasReviewOpenContext
---@param on_done fun(err: string|nil, level: "error"|nil)|nil
---@return { cancel: fun() }|nil
function M.open_pr(context, on_done)
	local command, err = configured_command()
	if not command then
		if on_done then
			on_done(err, "error")
		end
		return nil
	end
	return start_pr(context, command, false, function(open_err)
		if on_done then
			on_done(open_err, open_err and "error" or nil)
		end
	end)
end

return M
