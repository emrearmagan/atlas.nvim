local checkout = require("atlas.core.git.checkout")
local config = require("atlas.config")
local diff_session = require("atlas.pulls.diff.session")
local git = require("atlas.core.git")
local loading = require("atlas.ui.loading")
local logger = require("atlas.core.logger")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local reviewed_store = require("atlas.pulls.reviewed")
local viewer = require("atlas.pulls.diff.viewer")
local worktree = require("atlas.core.git.worktree")

local M = {}

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("AtlasDiffWorktrees", { clear = true }),
	callback = function()
		worktree.shutdown()
	end,
})

local function prune()
	worktree.prune()
	checkout.prune()
	reviewed_store.prune()
end

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
---@param on_prepared fun(root: string, base: string, head: string, source: AtlasDiffSource)
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

			on_prepared(root, base_hash, head_hash, { kind = "refs", base = base or head .. "^", head = head })
		end)
	end)
end

local function start_loading(message, context, on_done)
	local requests = request_scope.new()
	local options = vim.deepcopy(config.options.pulls.diff)
	---@cast options AtlasPullsDiffConfig
	options.open_cmd = config.diff_command()
	context.command = options.open_cmd

	local view = loading.open(message, requests.cancel, "diff")

	local function fail(title, description)
		requests.cancel()

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

	---@param root string
	---@param base string
	---@param head string
	---@param source AtlasDiffSource
	local function on_prepared(root, base, head, source)
		context.root = root
		context.base = base
		context.head = head

		-- Diffview uses revision buffers, so it doesn't need an LSP worktree.
		local lsp = options.lsp.enabled and options.open_cmd ~= "DiffviewOpen" and options.lsp or nil
		requests.run(function(done)
			return diff_session.new(source, root, base, head, {
				lsp = lsp,
				on_progress = function(update)
					view:update(update)
				end,
			}, done)
		end, function(session, err)
			if not session then
				fail("Unable to load changed files", err)
				return
			end

			local opened, open_err = pcall(viewer.open, session, options)
			if not opened then
				session:close()
				fail("Unable to open diff", open_err)
				return
			end

			view:finish()
			prune()
			if on_done then
				on_done(nil)
			end
		end)
	end

	return view, requests, fail, on_prepared
end

-- Accepts a PR reference: provider ID, repository name and PR ID.
---@param ref { provider: string, repo_full_name: string, id: string|number, root?: string }
---@param on_done (fun(err: string|nil))|nil
function M.open_pr(ref, on_done)
	local cwd = ref.root or git.default_cwd()
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

		view:update("Preparing repository...")
		requests.run(function(done)
			return checkout.prepare_diff(pr, cwd, function(message)
				view:update(message)
			end, done)
		end, function(prepared, prepare_err)
			if not prepared then
				fail("Unable to prepare repository", prepare_err)
				return
			end

			on_prepared(prepared.root, prepared.base_revision, prepared.head_revision, { kind = "pr", pr = pr })
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

---@param session AtlasDiffSession
function M.reopen(session)
	local source = session.source
	local root = session.range.root
	if source.kind == "pr" then
		local pr = source.pr
		M.open_pr({ provider = pr.provider, repo_full_name = pr.repo_full_name, id = pr.id, root = root })
		return
	end

	M.open_range({ base = source.base, head = source.head, root = root })
end

return M
