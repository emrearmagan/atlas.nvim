local M = {}

local checkout = require("atlas.core.git.checkout")
local logger = require("atlas.core.logger")

---@param requested AtlasPullsDiffOpenCommand|nil
---@return AtlasPullsDiffOpenCommand|nil open_cmd
---@return string|nil err
local function diff_open_command(requested)
	local config = require("atlas.config")
	local pulls_cfg = config.options.pulls or {}
	local cmd = vim.trim(tostring(requested or (pulls_cfg.diff or {}).open_cmd or ""))
	if cmd == "" then
		return nil, "diff.open_cmd is not configured"
	end
	if cmd ~= "AtlasDiff" and cmd ~= "DiffviewOpen" and cmd ~= "CodeDiff" then
		return nil, "Unsupported diff.open_cmd: " .. cmd
	end

	if vim.fn.exists(":" .. cmd) ~= 2 then
		return nil, string.format("diff.open_cmd command not found: %s", cmd)
	end

	---@cast cmd AtlasPullsDiffOpenCommand
	return cmd, nil
end
---@class PullsDiffOpenOptions
---@field git_root string
---@field base_revision string
---@field head_revision string
---@field review AtlasReviewOpenContext|nil
---@field fetch_branches (fun(pr: PullRequest|nil, on_done: fun(err: string|nil)): { cancel: fun() }|nil)|nil
---@field open_cmd AtlasPullsDiffOpenCommand|nil
---@field force_refresh boolean|nil
---@field refresh_pull_request boolean|nil

---@class PullsDiffPRContext
---@field pr PullRequest
---@field provider PullsProvider|nil
---@field current_user PullsUser|nil

---@param repo_path string
---@param range string
---@return string|nil err
local function open_diffview(repo_path, range)
	local previous_path = vim.fn.fnameescape(vim.fn.getcwd())
	local ok, err = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(repo_path))
		local opened, open_err = pcall(vim.cmd, "DiffviewOpen " .. range)
		vim.cmd("cd " .. previous_path)
		if not opened then
			error(open_err)
		end
	end)
	return not ok and tostring(err) or nil
end

---@param repo_path string
---@param range string
---@param view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
local function open_codediff(repo_path, range, view, on_done)
	local finished = false
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
		view:finish()
		on_done(err)
	end

	-- CodeDiff opens its own tab, so close the temporary one.
	autocmd_id = vim.api.nvim_create_autocmd("User", {
		pattern = "CodeDiffOpen",
		once = true,
		callback = function()
			vim.schedule(function()
				finish(nil)
			end)
		end,
	})
	local ok, err = pcall(vim.api.nvim_win_call, view.win, function()
		vim.cmd("tcd " .. vim.fn.fnameescape(repo_path))
		vim.cmd("CodeDiff " .. range)
	end)
	if not ok then
		finish(tostring(err))
	end

	return {
		cancel = function()
			if finished then
				return
			end
			finished = true
			if autocmd_id then
				pcall(vim.api.nvim_del_autocmd, autocmd_id)
				autocmd_id = nil
			end
		end,
	}
end

---@param opts PullsDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@param loading_target AtlasLoadingTarget|nil
---@return { cancel: fun() }|nil
function M.open(opts, on_done, loading_target)
	local open_cmd, command_err = diff_open_command(opts.open_cmd)
	if not open_cmd then
		if on_done then
			on_done(command_err)
		end
		return nil
	end

	local root = tostring(opts.git_root or "")
	local base = vim.trim(tostring(opts.base_revision or ""))
	local head = vim.trim(tostring(opts.head_revision or ""))
	if root == "" or base == "" or head == "" then
		if on_done then
			on_done("Repository path, base revision, and head revision are required")
		end
		return nil
	end

	local review = open_cmd == "AtlasDiff" and opts.review or nil
	local loading = require("atlas.ui.components.loading")
	local prepare_request
	local launch_request
	local completed = false
	local cancelled = false
	local view
	local function cancel()
		if cancelled or completed then
			return
		end
		cancelled = true
		if prepare_request then
			pcall(prepare_request.cancel)
			prepare_request = nil
		end
		if launch_request then
			pcall(launch_request.cancel)
			launch_request = nil
		end
		if view then
			view:finish()
		end
	end
	view = loading.open("Preparing diff...", cancel, loading_target)
	local operation = { cancel = cancel }

	---@param err string|nil
	local function complete(err)
		if completed or cancelled then
			return
		end
		completed = true
		prepare_request = nil
		launch_request = nil
		if on_done then
			on_done(err)
		end
	end

	---@param err string
	local function fail(err)
		view:finish()
		complete(err)
	end

	---@param prepared_review AtlasPreparedReviewContext|nil
	---@param prepared_base string
	---@param prepared_head string
	---@return fun(target: AtlasLoadingTarget|nil)
	local function reload(prepared_review, prepared_base, prepared_head)
		return function(target)
			M.open({
				git_root = root,
				base_revision = prepared_base,
				head_revision = prepared_head,
				review = prepared_review,
				fetch_branches = opts.fetch_branches,
				open_cmd = open_cmd,
				force_refresh = true,
				refresh_pull_request = true,
			}, function(reload_err)
				if reload_err then
					vim.notify("[Atlas Review] Unable to reload diff: " .. reload_err, vim.log.levels.ERROR)
				end
			end, target)
		end
	end

	---@param prepared_review AtlasPreparedReviewContext|nil
	---@param commits PullsCommit[]
	---@param prepared_base string
	---@param prepared_head string
	local function launch(prepared_review, commits, prepared_base, prepared_head)
		local range = prepared_base .. "..." .. prepared_head
		logger.loginfo("diff.open", { repo_path = root, command = open_cmd .. " " .. range })

		if open_cmd == "AtlasDiff" then
			local restart = reload(prepared_review, prepared_base, prepared_head)
			local explorer = require("atlas.pulls.diff.atlas.explorer")
			local explorer_options = explorer.options()
			local finished = false
			local handle = require("atlas.pulls.diff.atlas.git").prepare({
				git_root = root,
				base_revision = prepared_base,
				head_revision = prepared_head,
				filter = function(files)
					return explorer.filter(files, explorer_options)
				end,
				on_progress = function(message)
					view:update(message)
				end,
			}, function(prepared, err)
				finished = true
				launch_request = nil
				if cancelled then
					return
				end
				if not prepared then
					fail(tostring(err or "Unable to prepare diff"))
					return
				end
				local target = view:handoff()
				if not target then
					complete("The diff loading view was closed")
					return
				end
				local ok, open_err = pcall(require("atlas.pulls.diff.atlas").open, {
					diff = prepared,
					explorer = explorer_options,
					review = prepared_review,
					commits = commits,
					reload = restart,
					target = target,
				})
				if not ok then
					open_err = tostring(open_err)
				end
				complete(open_err)
			end)
			if finished or cancelled then
				handle.cancel()
			else
				launch_request = handle
			end
			return
		end
		view:update("Opening diff...")
		if open_cmd == "CodeDiff" then
			launch_request = open_codediff(root, range, view, function(err)
				launch_request = nil
				complete(err)
			end)
			return
		end

		view:finish()
		complete(open_diffview(root, range))
	end

	-- Preparation may finish before run() returns its request handle.
	local preparation_done = false
	local ok, handle = pcall(require("atlas.pulls.diff.shared.prepare").run, {
		review = review,
		fetch_branches = opts.fetch_branches,
		force_refresh = opts.force_refresh,
		refresh_pull_request = opts.refresh_pull_request,
		include_commits = open_cmd == "AtlasDiff",
		on_progress = function(message)
			view:update(message)
		end,
	}, function(result, err)
		preparation_done = true
		prepare_request = nil
		if cancelled then
			return
		end
		if not result then
			fail(tostring(err or "Unable to prepare diff"))
			return
		end
		local launched, launch_err = pcall(function()
			local prepared_base, prepared_head = base, head
			if opts.refresh_pull_request and result.review then
				local revision_err
				prepared_base, prepared_head, revision_err = checkout.pr_diff_revisions(result.review.pr)
				if not prepared_base or not prepared_head then
					fail(tostring(revision_err or "Unable to refresh pull request revisions"))
					return
				end
			end
			launch(result.review, result.commits, prepared_base, prepared_head)
		end)
		if not launched then
			fail(tostring(launch_err))
		end
	end)
	if not ok then
		view:finish()
		complete(tostring(handle))
		return nil
	end
	if preparation_done or completed or cancelled then
		if handle then
			pcall(handle.cancel)
		end
	else
		prepare_request = handle
	end
	return operation
end

---@param range string
function M.open_range(range)
	local separator = range:find("...", 1, true)
	local base = separator and vim.trim(range:sub(1, separator - 1)) or ""
	local head = separator and vim.trim(range:sub(separator + 3)) or ""
	if base == "" or head == "" then
		vim.notify("[AtlasDiff] Expected an explicit base...head range", vim.log.levels.ERROR)
		return
	end
	M.open({
		git_root = vim.fn.getcwd(),
		base_revision = base,
		head_revision = head,
		open_cmd = "AtlasDiff",
	}, function(err)
		if err then
			vim.notify("[AtlasDiff] " .. err, vim.log.levels.ERROR)
		end
	end)
end

---@param context PullsDiffPRContext
---@param on_done fun(err: string|nil, level: "warn"|"error"|nil)|nil
---@return { cancel: fun() }|nil
function M.open_pr(context, on_done)
	local pr = context.pr
	local resolved_path, resolve_err =
		checkout.resolve_repo_path_for_pr(pr, { require_git = true, require_existing = true })
	if not resolved_path then
		if on_done then
			on_done(tostring(resolve_err or "Local repo not found"), "warn")
		end
		return nil
	end

	local base_revision, head_revision, revision_err = checkout.pr_diff_revisions(pr)
	if not base_revision or not head_revision then
		if on_done then
			local level = revision_err == "PR branch refs are missing" and "warn" or "error"
			on_done(tostring(revision_err or "Unable to resolve pull request revisions"), level)
		end
		return nil
	end

	---@param current_pr PullRequest|nil
	---@param done fun(err: string|nil)
	---@return { cancel: fun() }
	local function fetch_branches(current_pr, done)
		return checkout.fetch_pr_branches(current_pr or pr, resolved_path, done)
	end

	return M.open({
		git_root = resolved_path,
		base_revision = base_revision,
		head_revision = head_revision,
		review = context.provider and {
			provider = context.provider,
			pr = pr,
			current_user = context.current_user,
		} or nil,
		fetch_branches = fetch_branches,
	}, function(err)
		if err then
			logger.logerror("diff.open failed", { pr_id = pr.id, error = tostring(err) })
		end
		if on_done then
			on_done(err, err and "error" or nil)
		end
	end)
end

return M
