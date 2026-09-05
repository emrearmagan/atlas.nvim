local M = {}

local checkout = require("atlas.core.git.checkout")
local config = require("atlas.config")
local git = require("atlas.core.git")
local loading = require("atlas.pulls.diff.ui.loading")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local review_api = require("atlas.pulls.diff.review")
local session_api = require("atlas.pulls.diff.session")

local VIEWERS = {
	AtlasDiff = { id = "atlas", open = require("atlas.pulls.diff.atlas").open },
	CodeDiff = { id = "codediff", open = require("atlas.pulls.diff.codediff").open },
	DiffviewOpen = { id = "diffview", open = require("atlas.pulls.diff.diffview").open },
}

---@param command string|nil
---@return string
local function diff_command(command)
	command = vim.trim(command or config.options.pulls.diff.open_cmd or "")
	return command ~= "" and command or "AtlasDiff"
end

---@param message string
---@param context table
---@param on_done (fun(err: string|nil))|nil
---@return AtlasLoadingView, AtlasRequestScope, fun(err: string|nil)
local function start_loading(message, context, on_done)
	local requests = request_scope.new()
	local view = loading.open(message, requests.cancel)
	logger.loginfo("diff.open", context)

	local function finish(err)
		requests.cancel()
		view:finish()
		if err then
			context.error = tostring(err)
			logger.logerror("diff.open failed", context)
		end
		if on_done then
			on_done(err)
		end
	end

	return view, requests, finish
end

---@param command string
---@param source AtlasDiffSource
---@return string|nil
local function open_command(command, source)
	local tabpage
	local ok, err = pcall(function()
		vim.cmd("tabnew")
		tabpage = vim.api.nvim_get_current_tabpage()
		vim.cmd("tcd " .. vim.fn.fnameescape(source.root))
		vim.api.nvim_cmd({
			cmd = command,
			args = { source.base_revision .. "..." .. source.head_revision },
		}, {})
	end)
	if not ok and tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tabpage) .. "tabclose")
	end
	return not ok and tostring(err) or nil
end

---@param command string
---@param data { source: AtlasDiffSource, review: AtlasDiffReview|nil, commits: PullsCommit[], warnings: string[] }
---@param open_again fun(on_done: fun(err: string|nil))
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }|nil
local function open_viewer(command, data, open_again, on_done)
	local viewer = VIEWERS[command]
	if not viewer then
		on_done(open_command(command, data.source))
		return nil
	end

	local session = session_api.new({
		viewer_id = viewer.id,
		source = data.source,
		review = data.review,
		commits = data.commits,
		open_again = open_again,
	})
	return viewer.open(session, function(err)
		if err then
			session_api.detach(session, "open_failed")
		elseif #data.warnings > 0 then
			session_api.notify(session, "warn", table.concat(data.warnings, "; "))
		end
		on_done(err)
	end)
end

---@param opts { provider: PullsProvider, current_user: PullsUser|nil, root: string|nil }
---@param pr PullRequest
---@param viewer { id: string }|nil
---@param view AtlasLoadingView
---@param requests AtlasRequestScope
---@param on_done fun(data: { source: AtlasDiffSource, review: AtlasDiffReview|nil, commits: PullsCommit[], warnings: string[] }|nil, err: string|nil)
local function load_pr(opts, pr, viewer, view, requests, on_done)
	local loaders = {
		source = function(done)
			return checkout.prepare_diff(pr, opts.root, function(message)
				view:update(message)
			end, done)
		end,
	}

	if viewer then
		loaders.review = function(done)
			return review_api.load(opts.provider, pr, opts.current_user, function(review, warnings)
				done({ review = review, warnings = warnings }, nil)
			end)
		end
	end

	local core = opts.provider.capabilities.core
	if viewer and viewer.id == "atlas" and core.fetch_commits then
		loaders.commits = function(done)
			return core.fetch_commits(pr, { force_refresh = true }, done)
		end
	end

	view:update("Loading diff data...")
	requests.all(
		loaders,
		vim.schedule_wrap(function(values, errors)
			if errors.source then
				on_done(nil, errors.source)
				return
			end

			local loaded_review = values.review
			local warnings = loaded_review and loaded_review.warnings or {}
			if errors.commits then
				warnings[#warnings + 1] = "Unable to load commits: " .. tostring(errors.commits)
			end
			on_done({
				source = values.source,
				review = loaded_review and loaded_review.review or nil,
				commits = values.commits or {},
				warnings = warnings,
			}, nil)
		end)
	)
end

---@param opts { provider: PullsProvider, ref: PullRequestRef, current_user?: PullsUser, root?: string, command?: string }
---@param on_done (fun(err: string|nil))|nil
function M.open_pr(opts, on_done)
	local command = diff_command(opts.command)
	local viewer = VIEWERS[command]
	local context = {
		viewer = viewer and viewer.id or command,
		provider = opts.provider.id,
		repo = opts.ref.repo_full_name,
		pr_id = opts.ref.id,
	}
	local view, requests, finish = start_loading("Loading pull request...", context, on_done)

	requests.run(
		function(done)
			return opts.provider.capabilities.core.fetch_by_refs({ opts.ref }, { force_refresh = true }, done)
		end,
		vim.schedule_wrap(function(pulls, err)
			local pr = pulls and pulls[1]
			if not pr then
				finish(err or "Unable to load pull request")
				return
			end

			load_pr(opts, pr, viewer, view, requests, function(data, load_err)
				if not data then
					finish(load_err)
					return
				end
				requests.run(function(done)
					return open_viewer(command, data, function(reopen_done)
						M.open_pr({
							provider = opts.provider,
							ref = opts.ref,
							current_user = opts.current_user,
							root = opts.root,
							command = command,
						}, reopen_done)
					end, done)
				end, finish)
			end)
		end)
	)
end

---@param opts { root: string, base: string, head: string, command?: string }
---@param on_done (fun(err: string|nil))|nil
function M.open_range(opts, on_done)
	local command = diff_command(opts.command)
	local viewer = VIEWERS[command]
	local source = {
		root = opts.root,
		base_revision = opts.base,
		head_revision = opts.head,
	}
	local context = {
		viewer = viewer and viewer.id or command,
		root = source.root,
		base_revision = source.base_revision,
		head_revision = source.head_revision,
	}
	local _, requests, finish = start_loading("Preparing diff...", context, on_done)
	local data = { source = source, commits = {}, warnings = {} }

	requests.run(function(done)
		return open_viewer(command, data, function(reopen_done)
			M.open_range({
				root = source.root,
				base = source.base_revision,
				head = source.head_revision,
				command = command,
			}, reopen_done)
		end, done)
	end, finish)
end

---@param value string
---@param command string|nil
function M.open_pull_request(value, command)
	local target, err = providers.resolve(value)
	if not target or target.domain ~= "pulls" or target.entity ~= "pr" then
		notify.error(err or "Expected a pull request URL", { vim_notify = true })
		return
	end
	if not config.provider_options(target.provider) then
		notify.error("Pull request provider is not configured: " .. target.provider, { vim_notify = true })
		return
	end

	local provider = providers.load(target.provider, "pulls")
	if not provider then
		notify.error("Unable to load pull request provider: " .. target.provider, { vim_notify = true })
		return
	end
	---@cast provider PullsProvider
	M.open_pr({
		provider = provider,
		ref = target --[[@as PullRequestRef]],
		command = command,
	}, function(open_err)
		if open_err then
			notify.error(open_err, { vim_notify = true })
		end
	end)
end

---@param value string
function M.open_argument(value)
	local separator = value:find("...", 1, true)
	if not separator then
		M.open_pull_request(value, "AtlasDiff")
		return
	end

	local base = vim.trim(value:sub(1, separator - 1))
	local head = vim.trim(value:sub(separator + 3))
	if base == "" or head == "" then
		notify.error("Expected an explicit base...head range", { vim_notify = true })
		return
	end
	local root, err = git.repo_root()
	if not root then
		notify.error(err or "Not in a git repository", { vim_notify = true })
		return
	end

	M.open_range({ root = root, base = base, head = head, command = "AtlasDiff" }, function(open_err)
		if open_err then
			notify.error(open_err, { vim_notify = true })
		end
	end)
end

return M
