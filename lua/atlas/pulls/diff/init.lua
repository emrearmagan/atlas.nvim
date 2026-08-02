local M = {}

local git = require("atlas.core.git")
local checkout = require("atlas.core.git.checkout")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")

---@param requested AtlasPullsDiffOpenCommand|string|nil
---@return AtlasPullsDiffOpenCommand|string|nil open_cmd
---@return string|nil err
local function configured_command(requested)
	local config = require("atlas.config")
	local pulls_cfg = config.options.pulls or {}
	local cmd = vim.trim(tostring(requested or (pulls_cfg.diff or {}).open_cmd or ""))
	if cmd == "" then
		return nil, "diff.open_cmd is not configured"
	end
	if vim.fn.exists(":" .. cmd) ~= 2 then
		return nil, string.format("diff.open_cmd command not found: %s", cmd)
	end

	return cmd, nil
end

---@class PullsDiffOpenOptions
---@field git_root string
---@field base_revision string
---@field head_revision string
---@field open_cmd AtlasPullsDiffOpenCommand|string|nil

---@param repo_path string
---@param range string
---@param view AtlasLoadingView
---@return string|nil err
local function open_diffview(repo_path, range, view)
	local ok, err = pcall(vim.api.nvim_win_call, view.win, function()
		vim.cmd("tcd " .. vim.fn.fnameescape(repo_path))
		vim.api.nvim_cmd({ cmd = "DiffviewOpen", args = { range } }, {})
	end)
	if not ok then
		return tostring(err)
	end
	return nil
end

---@param open_cmd string
---@param repo_path string
---@param range string
---@return string|nil err
local function open_external_diff(open_cmd, repo_path, range)
	local tabpage
	local ok, err = pcall(function()
		vim.cmd("tabnew")
		tabpage = vim.api.nvim_get_current_tabpage()
		vim.cmd("tcd " .. vim.fn.fnameescape(repo_path))
		vim.api.nvim_cmd({ cmd = open_cmd, args = { range } }, {})
	end)
	if not ok and tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tabpage) .. "tabclose")
	end
	return not ok and tostring(err) or nil
end

---@param repo_path string
---@param range string
---@param review AtlasPreparedReviewContext|nil
---@param view AtlasLoadingView
---@param reload (fun(target: AtlasLoadingTarget|nil))|nil
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
local function open_codediff(repo_path, range, review, view, reload, on_done)
	local finished = false
	local cancelled = false
	local opened_tabpage
	local autocmd_id

	local function finish(err)
		if finished then
			return
		end
		finished = true
		if autocmd_id then
			pcall(vim.api.nvim_del_autocmd, autocmd_id)
			autocmd_id = nil
		end
		if cancelled then
			return
		end
		view:finish()
		on_done(err)
	end

	-- CodeDiff opens its own tab, so close the temporary one.
	autocmd_id = vim.api.nvim_create_autocmd("User", {
		pattern = "CodeDiffOpen",
		callback = function(args)
			local tabpage = args.data and args.data.tabpage
			if not tabpage then
				return
			end
			local lifecycle_ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
			local session = lifecycle_ok and lifecycle.get_session(tabpage) or nil
			if not session then
				return
			end
			opened_tabpage = tabpage
			if cancelled then
				pcall(lifecycle.close, tabpage)
				finish(nil)
				return
			end
			local attach_err
			if review then
				local ok, review_err = pcall(function()
					return require("atlas.pulls.diff.codediff").attach(review, tabpage, { reload = reload })
				end)
				if not ok then
					attach_err = tostring(review_err)
				elseif review_err then
					attach_err = review_err
				end
			end
			vim.schedule(function()
				finish(attach_err and "Unable to attach review to CodeDiff: " .. attach_err or nil)
			end)
		end,
	})
	local ok, err = pcall(vim.api.nvim_win_call, view.win, function()
		vim.api.nvim_cmd({ cmd = "CodeDiff", args = { "--repo", repo_path, range } }, {})
	end)
	if not ok then
		finish(tostring(err))
	end
	vim.defer_fn(function()
		if not finished then
			finish("CodeDiff did not open; check CodeDiff notifications for details")
		end
	end, 15000)
	return {
		cancel = function()
			if finished or cancelled then
				return
			end
			cancelled = true
			if opened_tabpage then
				local loaded, lifecycle = pcall(require, "codediff.ui.lifecycle")
				if loaded then
					pcall(lifecycle.close, opened_tabpage)
				end
				finish(nil)
			end
		end,
	}
end

-- Prefer an existing checkout; nil makes Atlas use its shared cache.
---@param pr PullRequest
---@return string|nil
local function repository_path(pr)
	local cwd = vim.fn.getcwd()
	local resolver = require("atlas.commands.open.resolver")
	local current = resolver.local_repository(cwd)
	local target = require("atlas.commands.open.parser").parse(pr.link.html)
	if
		current
		and target
		and current.provider == target.provider
		and current.host:lower() == target.host:lower()
		and current.slug:lower() == pr.repo_full_name:lower()
	then
		return git.repo_root(cwd)
	end
	local path = checkout.resolve_repo_path_for_pr(pr, { require_git = true, require_existing = true })
	return path
end

---@class PullsDiffLaunchOptions
---@field git_root string
---@field base_revision string
---@field head_revision string
---@field open_cmd AtlasPullsDiffOpenCommand|string
---@field review AtlasPreparedReviewContext|nil
---@field commits PullsCommit[]
---@field reload fun(target: AtlasLoadingTarget|nil)

---@param opts PullsDiffLaunchOptions
---@param view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }|nil
local function launch_diff(opts, view, on_done)
	local range = opts.base_revision .. "..." .. opts.head_revision
	logger.loginfo("diff.open", { repo_path = opts.git_root, command = opts.open_cmd .. " " .. range })

	if opts.open_cmd == "AtlasDiff" then
		local explorer = require("atlas.pulls.diff.atlas.explorer")
		local explorer_options = explorer.options()
		local cancelled = false
		local request = require("atlas.pulls.diff.atlas.git").prepare({
			git_root = opts.git_root,
			base_revision = opts.base_revision,
			head_revision = opts.head_revision,
			filter = function(files)
				return explorer.filter(files, explorer_options)
			end,
			on_progress = function(message)
				view:update(message)
			end,
		}, function(prepared, err)
			vim.schedule(function()
				if cancelled then
					return
				end
				if not prepared then
					view:finish()
					on_done(tostring(err or "Unable to prepare diff"))
					return
				end
				local target = view:handoff()
				if not target then
					on_done("The diff loading view was closed")
					return
				end
				local open_err = require("atlas.pulls.diff.atlas").open({
					diff = prepared,
					explorer = explorer_options,
					review = opts.review,
					commits = opts.commits,
					reload = opts.reload,
					target = target,
				})
				on_done(open_err)
			end)
		end)
		return {
			cancel = function()
				cancelled = true
				request.cancel()
			end,
		}
	end

	if opts.open_cmd == "CodeDiff" then
		return open_codediff(opts.git_root, range, opts.review, view, opts.reload, on_done)
	end

	local err
	if opts.open_cmd == "DiffviewOpen" then
		err = open_diffview(opts.git_root, range, view)
	else
		err = open_external_diff(opts.open_cmd, opts.git_root, range)
	end
	view:finish()
	vim.schedule(function()
		on_done(err)
	end)
	return nil
end

---@param opts PullsDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@param loading_target AtlasLoadingTarget|nil
---@return { cancel: fun() }|nil
local function start_range(opts, on_done, loading_target)
	local open_cmd, command_err = configured_command(opts.open_cmd)
	local root = vim.trim(opts.git_root)
	local base = vim.trim(opts.base_revision)
	local head = vim.trim(opts.head_revision)
	if not open_cmd or root == "" or base == "" or head == "" then
		if on_done then
			on_done(command_err or "Repository path, base revision, and head revision are required")
		end
		return nil
	end

	local current
	local finished = false
	local cancelled = false
	local view
	local function cancel()
		if finished or cancelled then
			return
		end
		cancelled = true
		if current then
			current.cancel()
		end
		view:finish()
	end
	view = require("atlas.ui.components.loading").open("Preparing diff...", cancel, loading_target)

	local function reload(target)
		start_range(opts, function(err)
			if err then
				notify.error("Unable to reload diff: " .. err)
			end
		end, target)
	end

	current = launch_diff(
		{
			git_root = root,
			base_revision = base,
			head_revision = head,
			open_cmd = open_cmd,
			review = nil,
			commits = {},
			reload = reload,
		},
		view,
		function(err)
			if finished or cancelled then
				return
			end
			finished = true
			current = nil
			if on_done then
				on_done(err)
			end
		end
	)
	return { cancel = cancel }
end

---@param context AtlasReviewOpenContext
---@param requested AtlasPullsDiffOpenCommand|string|nil
---@param refresh boolean
---@param on_done fun(err: string|nil)|nil
---@param loading_target AtlasLoadingTarget|nil
---@return { cancel: fun() }|nil
local function start_pr(context, requested, refresh, on_done, loading_target)
	local open_cmd, command_err = configured_command(requested)
	if not open_cmd then
		if on_done then
			on_done(command_err)
		end
		return nil
	end

	local current
	local finished = false
	local cancelled = false
	local view
	local function cancel()
		if finished or cancelled then
			return
		end
		cancelled = true
		if current then
			current.cancel()
		end
		view:finish()
	end
	view = require("atlas.ui.components.loading").open("Preparing diff...", cancel, loading_target)

	local function complete(err)
		if finished or cancelled then
			return
		end
		finished = true
		current = nil
		if on_done then
			on_done(err)
		end
	end

	local function fail(err)
		view:finish()
		complete(err)
	end

	-- Provider caches may invoke callbacks before returning their request handle.
	local function later(callback, ...)
		local args = { ... }
		local count = select("#", ...)
		vim.schedule(function()
			if finished or cancelled then
				return
			end
			current = nil
			callback(unpack(args, 1, count))
		end)
	end

	---@param review AtlasPreparedReviewContext|nil
	---@param commits PullsCommit[]
	---@param root string
	---@param base string
	---@param head string
	local function launch(review, commits, root, base, head)
		local function reload(target)
			start_pr(context, open_cmd, true, function(err)
				if err then
					notify.error("Unable to reload diff: " .. err)
				end
			end, target)
		end
		current = launch_diff(
			{
				git_root = root,
				base_revision = base,
				head_revision = head,
				open_cmd = open_cmd,
				review = review,
				commits = commits,
				reload = reload,
			},
			view,
			function(err)
				later(complete, err)
			end
		)
	end

	---@param review AtlasPreparedReviewContext
	---@param root string
	---@param base string
	---@param head string
	local function load_commits(review, root, base, head)
		context = review
		if open_cmd ~= "AtlasDiff" or not context.provider.fetch_commits then
			launch(review, {}, root, base, head)
			return
		end
		view:update(refresh and "Refreshing commits..." or "Loading commits...")
		current = context.provider.fetch_commits(
			context.pr,
			refresh and { force_refresh = true } or {},
			function(commits, err)
				later(function()
					if err then
						table.insert(review.initial_review.warnings, "Unable to load commits: " .. tostring(err))
					end
					launch(review, commits or {}, root, base, head)
				end)
			end
		)
	end

	---@param root string
	---@param base string
	---@param head string
	local function load_review(root, base, head)
		if open_cmd ~= "AtlasDiff" and open_cmd ~= "CodeDiff" then
			launch(nil, {}, root, base, head)
			return
		end
		view:update(refresh and "Refreshing review..." or "Loading review...")
		current = require("atlas.pulls.diff.shared.review").load(context, { force_refresh = refresh }, function(review)
			later(load_commits, review, root, base, head)
		end)
	end

	local function load_repository()
		current = checkout.ensure_pr_repository(context.pr, repository_path(context.pr), function(message)
			view:update(message)
		end, function(root, err)
			later(function()
				if not root then
					fail(tostring(err or "Unable to load pull request repository"))
					return
				end
				local base, head, revision_err = checkout.pr_diff_revisions(context.pr)
				if not base or not head then
					fail(tostring(revision_err or "Unable to resolve pull request revisions"))
					return
				end
				load_review(root, base, head)
			end)
		end)
	end

	if refresh then
		view:update("Refreshing pull request...")
		current = context.provider.fetch_pullrequest(context.pr, { force_load = true }, function(pr, err)
			later(function()
				if not pr then
					fail(tostring(err or "Unable to refresh pull request"))
					return
				end
				context.pr = pr
				load_repository()
			end)
		end)
	else
		load_repository()
	end
	return { cancel = cancel }
end

---@param value string
---@return { cancel: fun() }|nil
local function open_pull_request(value)
	local parser = require("atlas.commands.open.parser")
	local resolver = require("atlas.commands.open.resolver")
	local target, target_err = parser.parse(value)
	if not target then
		notify.error(target_err or "Invalid pull request URL")
		return nil
	end
	if target.domain ~= "pulls" or target.entity ~= "pr" then
		notify.error("Expected a pull request URL")
		return nil
	end
	if not resolver.provider_configured(target) then
		notify.error("Pull request provider is not configured: " .. target.provider)
		return nil
	end

	---@type PullsProvider|nil
	local provider = resolver.load_provider(target)
	if not provider then
		notify.error("Unable to load pull request provider: " .. target.provider)
		return nil
	end

	local pr = resolver.pull_request_from_target(target)
	return start_pr(
		{
			provider = provider,
			pr = pr,
			current_user = nil,
		},
		"AtlasDiff",
		true,
		function(err)
			if err then
				notify.error(err)
			end
		end
	)
end

---@param opts PullsDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@return { cancel: fun() }|nil
function M.open_range(opts, on_done)
	return start_range(opts, on_done)
end

---@param range string
local function open_range_argument(range)
	local separator = range:find("...", 1, true)
	local base = separator and vim.trim(range:sub(1, separator - 1)) or ""
	local head = separator and vim.trim(range:sub(separator + 3)) or ""
	if base == "" or head == "" then
		notify.error("Expected an explicit base...head range")
		return
	end
	M.open_range({
		git_root = vim.fn.getcwd(),
		base_revision = base,
		head_revision = head,
		open_cmd = "AtlasDiff",
	}, function(err)
		if err then
			notify.error(err)
		end
	end)
end

---@param value string
function M.open_argument(value)
	if value:find("...", 1, true) then
		open_range_argument(value)
		return
	end
	open_pull_request(value)
end

---@param context AtlasReviewOpenContext
---@param on_done fun(err: string|nil, level: "error"|nil)|nil
---@return { cancel: fun() }|nil
function M.open_pr(context, on_done)
	local pr = context.pr
	return start_pr(context, nil, false, function(err)
		if err then
			logger.logerror("diff.open failed", { pr_id = pr.id, error = tostring(err) })
		end
		if on_done then
			on_done(err, err and "error" or nil)
		end
	end)
end

return M
