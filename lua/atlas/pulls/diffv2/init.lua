local checkout = require("atlas.core.git.checkout")
local config = require("atlas.config")
local diff_git = require("atlas.pulls.diffv2.git")
local git = require("atlas.core.git")
local loading = require("atlas.ui.loading")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local worktree = require("atlas.core.git.worktree")

local M = {}

---@class AtlasDiffV2Result
---@field kind "pr"|"commit"|"range"
---@field root string
---@field base_revision string
---@field head_revision string
---@field files { path: string, old_path?: string, status: string, additions?: integer, deletions?: integer, binary: boolean }[]
---@field options AtlasPullsDiffConfig
---@field pr PullRequest|nil
---@field commits PullsCommit[]
---@field review { data?: PullsReviewData, context?: PullsReviewContext }|nil
---@field current_user AtlasUser|nil
---@field notes { target: AtlasNoteTarget, items: AtlasNote[] }|nil
---@field worktree_root string|nil
---@field release fun() Call when closing the review to clean up its worktree.

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("AtlasDiffV2Worktrees", { clear = true }),
	callback = function()
		worktree.shutdown()
	end,
})

---@param root string
---@param revision string
---@param on_done fun(hash: string|nil, err: string|nil)
local function resolve_commit(root, revision, on_done)
	return git.run({ "rev-parse", "--verify", "--end-of-options", revision .. "^{commit}" }, {
		cwd = root,
		text = true,
	}, function(result)
		if result.code ~= 0 then
			on_done(nil, vim.trim(result.stderr))
			return
		end
		on_done(vim.trim(result.stdout), nil)
	end)
end

---@param root string
---@param base string|nil
---@param head string
---@param requests AtlasRequestScope
---@param on_prepared fun(kind: string, source: table)
---@param fail fun(title: string, description?: string)
local function prepare_commits(root, base, head, requests, on_prepared, fail)
	requests.run(function(done)
		return resolve_commit(root, head, done)
	end, function(head_hash, head_err)
		if not head_hash then
			fail("Unable to resolve commit: " .. head, head_err)
			return
		end
		requests.run(function(done)
			return resolve_commit(root, base or head_hash .. "^", done)
		end, function(base_hash, base_err)
			if not base_hash then
				fail("Unable to resolve base commit", base_err)
				return
			end
			on_prepared(base and "range" or "commit", {
				root = root,
				base_revision = base_hash,
				head_revision = head_hash,
			})
		end)
	end)
end

local function start_loading(message, context, on_done)
	local requests = request_scope.new()
	local options = vim.deepcopy(config.options.pulls.diff)
	---@cast options AtlasPullsDiffConfig
	options.open_cmd = vim.trim(options.open_cmd)
	if options.open_cmd == "" then
		options.open_cmd = "AtlasDiff"
	end
	context.command = options.open_cmd
	---@type AtlasDiffV2Result|nil
	local result
	local pending_worktree
	local function release_worktree()
		if pending_worktree then
			worktree.discard(pending_worktree.repo_root, pending_worktree.root)
			pending_worktree = nil
		end
		if result and result.worktree_root then
			worktree.discard(result.root, result.worktree_root)
		end
		result = nil
	end

	local function cancel()
		requests.cancel()
		release_worktree()
	end
	local view = loading.open(message, cancel)

	local function fail(title, description)
		cancel()
		local err = title
		if description and description ~= "" then
			err = title .. "\n\n" .. description
		end
		context.error = err
		logger.logerror("diff.open failed", context)
		view:error(err)
		if on_done then
			on_done(err)
		end
	end

	return view,
		requests,
		fail,
		function(kind, source, pr_data)
			pr_data = pr_data or {}
			context.root = source.root
			context.base = source.base_revision
			context.head = source.head_revision
			view:update("Loading changed files...")
			requests.run(function(done)
				return diff_git.load(source, done)
			end, function(diff, load_err)
				if not diff then
					fail("Unable to load changed files", load_err)
					return
				end
				local function complete(worktree_root)
					result = {
						kind = kind,
						root = source.root,
						base_revision = diff.base_revision,
						head_revision = source.head_revision,
						files = diff.files,
						options = options,
						pr = pr_data.pr,
						commits = pr_data.commits or {},
						review = pr_data.review,
						current_user = pr_data.current_user,
						notes = pr_data.notes,
						worktree_root = worktree_root,
						release = release_worktree,
					}
					pending_worktree = nil
				end

				if options.open_cmd ~= "AtlasDiff" or not options.lsp.enabled or #diff.files == 0 then
					complete()
					return
				end
				view:update("Preparing worktree...")
				local pr = pr_data.pr
				local dir, claim_err = worktree.claim({
					repo_root = source.root,
					head_sha = source.head_revision,
					repo_full_name = pr and pr.repo_full_name,
					pr_id = pr and pr.id,
				}, options.lsp)
				if not dir then
					notify.warn("LSP worktree unavailable: " .. claim_err)
					complete()
					return
				end
				pending_worktree = { repo_root = source.root, root = dir }
				worktree.prune(source.root)
				requests.run(function(done)
					return worktree.ensure({
						repo_root = source.root,
						head_sha = source.head_revision,
						dir = dir,
						link = options.lsp.link,
					}, done)
				end, function(path, prepare_err)
					if not path then
						release_worktree()
						notify.warn("LSP worktree unavailable: " .. prepare_err)
					end
					complete(path)
				end)
			end)
		end
end

-- Accepts a PR reference: provider ID, repository name and PR ID.
---@param ref { provider: string, repo_full_name: string, id: string|number }
---@param on_done (fun(err: string|nil))|nil
function M.open_pr(ref, on_done)
	local cwd = git.default_cwd()
	local view, requests, fail, on_prepared = start_loading("Loading pull request...", {
		kind = "pr",
		provider = ref.provider,
		repo = ref.repo_full_name,
		pr_id = ref.id,
	}, on_done)
	if not config.provider_options(ref.provider) then
		fail("Pull request provider is not configured: " .. ref.provider)
		return
	end

	local provider = providers.load(ref.provider, "pulls")
	if not provider then
		fail("Unable to load pull request provider: " .. ref.provider)
		return
	end
	---@cast provider PullsProvider

	requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, done)
	end, function(pulls, err)
		local pr = pulls and pulls[1]
		if not pr then
			fail("Unable to load pull request", err)
			return
		end
		local capabilities = provider.capabilities
		local starts = {
			repository = function(done)
				return checkout.prepare_diff(pr, cwd, function(message)
					view:update(message)
				end, function(source, prepare_err)
					if not source then
						fail("Unable to prepare repository", prepare_err)
						return
					end
					done(source, nil)
				end)
			end,
		}
		if capabilities.core.fetch_commits then
			starts.commits = function(done)
				return capabilities.core.fetch_commits(pr, { force_refresh = true }, done)
			end
		end
		if capabilities.reviews then
			starts.review = function(done)
				return capabilities.reviews.fetch(pr, { force_refresh = true }, done)
			end
			if capabilities.reviews.fetch_review_context then
				starts.review_context = function(done)
					return capabilities.reviews.fetch_review_context(pr, { force_refresh = true }, done)
				end
			end
		end
		if capabilities.users then
			starts.current_user = capabilities.users.fetch_user
		end

		view:update("Preparing repository and review data...")
		requests.all(starts, function(values, errors)
			for _, item in ipairs({
				{ "commits", "commits" },
				{ "review", "review data" },
				{ "review_context", "review context" },
				{ "current_user", "current user" },
			}) do
				if errors[item[1]] then
					notify.warn("Unable to load " .. item[2] .. ": " .. errors[item[1]])
				end
			end
			local target, notes_err = notes.target_for_pull_request(pr)
			local local_notes
			if target then
				local_notes, notes_err = notes.list(target)
			end
			if notes_err then
				notify.warn("Unable to load notes: " .. notes_err)
			end
			on_prepared("pr", values.repository, {
				pr = pr,
				commits = values.commits,
				review = (values.review or values.review_context)
					and { data = values.review, context = values.review_context },
				current_user = values.current_user,
				notes = target and { target = target, items = local_notes or {} },
			})
		end)
	end)
end

-- Accepts a commit revision and an optional repository path.
---@param opts { commit: string, root?: string }
---@param on_done (fun(err: string|nil))|nil
function M.open_commit(opts, on_done)
	local cwd = opts.root or git.default_cwd()
	local _, requests, fail, on_prepared = start_loading("Preparing commit diff...", {
		kind = "commit",
		root = cwd,
		commit = opts.commit,
	}, on_done)
	requests.run(function(done)
		return git.repo_root(cwd, done)
	end, function(root, err)
		if not root then
			fail("Unable to open diff", err)
			return
		end
		prepare_commits(root, nil, opts.commit, requests, on_prepared, fail)
	end)
end

-- Accepts base/head revisions and an optional repository path.
---@param opts { base: string, head: string, root?: string }
---@param on_done (fun(err: string|nil))|nil
function M.open_range(opts, on_done)
	local cwd = opts.root or git.default_cwd()
	local _, requests, fail, on_prepared = start_loading("Preparing diff...", {
		kind = "range",
		root = cwd,
		base = opts.base,
		head = opts.head,
	}, on_done)
	requests.run(function(done)
		return git.repo_root(cwd, done)
	end, function(root, err)
		if not root then
			fail("Unable to open diff", err)
			return
		end
		prepare_commits(root, opts.base, opts.head, requests, on_prepared, fail)
	end)
end

return M
