local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")

local CLONE_STALE_SECONDS = 30 * 24 * 60 * 60 -- 30 days
local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

---@return AtlasGitTransport transport
local function configured_git_transport()
	return config.options.pulls.git_transport == "ssh" and "ssh" or "https"
end

-- Fewer `*` wins, then longer literal text, then alphabetical key.
local function more_specific(a, b)
	if a.stars ~= b.stars then
		return a.stars < b.stars
	end
	if a.literal ~= b.literal then
		return a.literal > b.literal
	end
	return a.key < b.key
end

---Each `*` in a key matches within one path segment and fills the next `*` in its path.
---@param repo_paths table<string, string> `pulls.repo_config.paths`
---@param repo_name string
---@return string|nil path
---@return string|nil err
function M.resolve_path(repo_paths, repo_name)
	local best
	for key, value in pairs(repo_paths) do
		if type(key) ~= "string" or type(value) ~= "string" then
			return nil, "repo_paths keys and values must be strings"
		end

		local pattern, stars = key:gsub(LUA_PATTERN_SPECIALS, "%%%0"):gsub("%*", "([^/]+)")
		local captures = { repo_name:match("^" .. pattern .. "$") }
		if captures[1] and value ~= "" then
			local candidate = { key = key, value = value, stars = stars, literal = #key - stars, captures = captures }
			if not best or more_specific(candidate, best) then
				best = candidate
			end
		end
	end

	if not best then
		return nil, string.format("no repo_paths mapping for '%s'", repo_name)
	end

	local index = 0
	local path, value_stars = best.value:gsub("%*", function()
		index = index + 1
		return best.captures[index]
	end)
	if value_stars ~= best.stars then
		return nil, string.format("repo_paths '%s' and '%s' need the same number of *", best.key, best.value)
	end
	return vim.fn.fnamemodify(vim.fs.normalize(path), ":p"), nil
end

---@param repo_name string
---@param opts {require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
local function resolve_repo_path(repo_name, opts)
	local path, err = M.resolve_path((config.options.pulls.repo_config or {}).paths or {}, repo_name)
	if path and opts.require_existing ~= false and vim.fn.isdirectory(path) ~= 1 then
		return nil, string.format("mapped path does not exist: %s", path)
	end
	return path, err
end

---@param pr PullRequest
---@param opts { require_existing?: boolean }
---@param on_done fun(repo_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.resolve_repo_path_for_pr(pr, opts, on_done)
	local root, err = resolve_repo_path(pr.repo_full_name, opts)
	if not root then
		on_done(nil, err)
		return nil
	end
	local target = providers.resolve(pr.link.html)
	return git.local_repository(root, function(current)
		if
			current
			and target
			and (current.provider ~= target.provider or current.host:lower() ~= target.host:lower())
		then
			on_done(nil, "mapped repository does not match the pull request remote: " .. root)
			return
		end
		on_done(root, nil)
	end)
end

---@param pr PullRequest
---@return string|nil base_revision
---@return string|nil head_revision
---@return string|nil err
local function pr_diff_revisions(pr)
	local base = pr.destination.commit_hash
	local head = pr.source.commit_hash
	if base == "" then
		return nil, nil, "Pull request base commit is missing"
	end
	if head == "" then
		return nil, nil, "Pull request head commit is missing"
	end
	return base, head, nil
end

---@param ref PullsRef
---@return string remote_ref
local function fetch_ref(ref)
	return ref.fetch_ref or (ref.branch ~= "" and "refs/heads/" .. ref.branch or "")
end

---@param ref PullsRef
---@param transport AtlasGitTransport
---@param provider string
---@return string|nil remote URL, or nil to fetch from the base remote
---@return string|nil err
local function source_remote(ref, transport, provider)
	if ref.https_url ~= nil or ref.ssh_url ~= nil then
		local selected = ref.https_url
		if transport == "ssh" then
			selected = ref.ssh_url
		end
		if not selected or selected == "" then
			return "", string.format("%s did not provide a %s Git remote URL", provider, transport)
		end
		return selected, nil
	end
	return nil, nil
end

---@param root string
---@param target AtlasTarget|nil
---@param on_done fun(remote: AtlasGitRemote|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function repository_remote(root, target, on_done)
	if not target then
		on_done(nil, nil)
		return nil
	end
	return git.list_repository_remotes(root, function(remotes, err)
		on_done(remotes and git.remote_for_repository(remotes, target) or nil, err)
	end)
end

---@param pr PullRequest
---@param repo_path string
---@param on_done fun(err: string|nil)
---@param opts AtlasGitFetchOptions|nil
---@return { cancel: fun() }|nil
local function fetch_pr_refs(pr, repo_path, on_done, opts)
	local base_revision, head_revision, revision_err = pr_diff_revisions(pr)
	if not base_revision or not head_revision then
		on_done(revision_err)
		return nil
	end

	local scope = requests.new()
	local refs = {}
	local index = 0
	local base_remote = "origin"

	local function verify_commits()
		scope.run(function(done)
			return git.check_commits(repo_path, { base_revision, head_revision }, done)
		end, function(exists, err)
			if exists then
				if not exists[1] then
					err = "Pull request base commit is unavailable: " .. base_revision
				elseif not exists[2] then
					err = "Pull request head commit is unavailable: " .. head_revision
				end
			end
			on_done(err)
		end)
	end

	local function next_ref()
		index = index + 1
		local ref = refs[index]
		if not ref then
			verify_commits()
			return
		end
		scope.run(function(done)
			return git.fetch_refs(repo_path, ref.remote, { ref.ref }, done, opts)
		end, function(ok, err)
			if not ok then
				on_done(err)
				return
			end
			next_ref()
		end)
	end

	local function queue_refs(exists)
		if not exists[1] then
			local ref = fetch_ref(pr.destination)
			if ref ~= "" then
				refs[#refs + 1] = { remote = base_remote, ref = ref }
			end
		end
		if not exists[2] then
			local remote, remote_err = source_remote(pr.source, configured_git_transport(), pr.provider)
			if remote_err then
				on_done(remote_err)
				return
			end
			local ref = fetch_ref(pr.source)
			if ref ~= "" then
				refs[#refs + 1] = { remote = remote or base_remote, ref = ref }
			end
		end
		next_ref()
	end

	scope.run(function(done)
		return git.check_commits(repo_path, { base_revision, head_revision }, done)
	end, function(exists, err)
		if not exists then
			on_done(err)
			return
		end
		if exists[1] and exists[2] then
			on_done(nil)
			return
		end
		scope.run(function(done)
			return repository_remote(repo_path, pr.link and providers.resolve(pr.link.html) or nil, done)
		end, function(remote)
			base_remote = remote and remote.name or base_remote
			queue_refs(exists)
		end)
	end)
	return scope
end

---@return string
local function clones_root()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "atlas", "repos")
end

---@param pr PullRequest
---@return string|nil cache_path
---@return string|nil remote_url
local function cached_pr_repository(pr)
	local target = providers.resolve(pr.link.html)
	if not target or target.domain ~= "pulls" or target.entity ~= "pr" then
		return nil, nil
	end
	---@cast target AtlasTarget
	local repository = pr.repo_full_name
	local transport = configured_git_transport()
	local cache_path = vim.fs.joinpath(clones_root(), target.host, repository)
	local advertised = pr.destination.https_url
	if transport == "ssh" then
		advertised = pr.destination.ssh_url
	end
	if advertised and advertised ~= "" then
		return cache_path, advertised
	end

	if transport == "ssh" then
		return cache_path, string.format("git@%s:%s.git", target.host, repository)
	end
	return cache_path, target.repository_url
end

---@param action string
---@param phase string
---@param percent integer
---@return string
local function progress_message(action, phase, percent)
	return string.format("%s...\n%s %d%% / 100%%", action, phase, percent)
end

---@param pr PullRequest
---@param repo_path string|nil
---@param on_progress fun(message: string)
---@param on_done fun(repo_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function ensure_repository(pr, repo_path, on_progress, on_done)
	local scope = requests.new()

	---@param path string
	local function fetch(path)
		on_progress("Fetching pull request refs...")
		scope.run(function(done)
			return fetch_pr_refs(pr, path, done, {
				console = true,
				on_progress = function(phase, percent)
					on_progress(progress_message("Fetching pull request refs", phase, percent))
				end,
			})
		end, function(err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(path, nil)
		end)
	end

	if repo_path then
		fetch(repo_path)
		return scope
	end

	local path, clone_url = cached_pr_repository(pr)
	if not path or not clone_url then
		on_done(nil, "Unable to determine the pull request repository")
		return nil
	end
	scope.run(function(done)
		return git.is_inside_work_tree(path, done)
	end, function(exists)
		if exists then
			fetch(path)
			return
		end
		if vim.fn.isdirectory(path) == 1 then
			vim.fn.delete(path, "rf")
		end
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		on_progress("Cloning repository...")
		-- Leave the cache without a checkout; Git loads trees and blobs when a diff needs them.
		scope.run(function(done)
			return git.run(
				{
					"clone",
					"--progress",
					"--filter=tree:0",
					"--no-checkout",
					"--single-branch",
					"--no-tags",
					clone_url,
					path,
				},
				{ text = true, console = true },
				done,
				function(phase, percent)
					on_progress(progress_message("Cloning repository", phase, percent))
				end
			)
		end, function(result)
			if result.code ~= 0 then
				vim.fn.delete(path, "rf")
				local err = vim.trim(tostring(result.stderr or ""))
				on_done(nil, err ~= "" and err or "Unable to clone pull request repository")
				return
			end
			fetch(path)
		end)
	end)

	return scope
end

---@param dir string
---@param now integer
local function prune_clones(dir, now)
	local git_dir = vim.fs.joinpath(dir, ".git")
	if vim.fn.isdirectory(git_dir) == 1 then
		local stat = vim.uv.fs_stat(vim.fs.joinpath(git_dir, "FETCH_HEAD")) or vim.uv.fs_stat(git_dir)
		if stat and now - stat.mtime.sec > CLONE_STALE_SECONDS then
			logger.loginfo("checkout.prune removing stale clone", { dir = dir })
			vim.fn.delete(dir, "rf")
		end
		return
	end
	for name, kind in vim.fs.dir(dir) do
		if kind == "directory" then
			prune_clones(vim.fs.joinpath(dir, name), now)
		end
	end
	vim.fn.delete(dir, "d")
end

function M.prune()
	local root = clones_root()
	if vim.fn.isdirectory(root) == 1 then
		prune_clones(root, os.time())
	end
end

---@param path string|nil Directory inside the checkout; nil uses the current working directory
---@param repo_full_name string
---@param repo_url string|nil
---@param on_done fun(root: string|nil, err: string|nil, remote: string|nil)
---@return AtlasRequestScope
local function matching_root(path, repo_full_name, repo_url, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return git.repo_root(path, done)
	end, function(root, root_err)
		if not root then
			on_done(nil, root_err)
			return
		end
		scope.run(function(done)
			return repository_remote(root, repo_url and providers.resolve(repo_url) or nil, done)
		end, function(remote)
			if not remote then
				on_done(nil, string.format("no remote of %s matches %s", root, repo_full_name))
				return
			end
			on_done(root, nil, remote.name)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param root string|nil
---@param on_progress fun(message: string)
---@param on_done fun(source: { root: string, base_revision: string, head_revision: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.prepare_diff(pr, root, on_progress, on_done)
	local base, head, revision_err = pr_diff_revisions(pr)
	if not base or not head then
		on_done(nil, revision_err)
		return nil
	end

	local scope = requests.new()
	local function prepare(repo_path)
		scope.run(function(done)
			return ensure_repository(pr, repo_path, on_progress, done)
		end, function(path, err)
			if not path then
				on_done(nil, err or "Unable to load pull request repository")
				return
			end
			on_done({ root = path, base_revision = base, head_revision = head }, nil)
		end)
	end
	scope.run(function(done)
		return matching_root(root, pr.repo_full_name, pr.link.html, done)
	end, function(repo_path)
		if repo_path then
			prepare(repo_path)
			return
		end
		scope.run(function(done)
			return M.resolve_repo_path_for_pr(pr, { require_existing = true }, done)
		end, function(mapped_path)
			if not mapped_path then
				prepare(nil)
				return
			end
			scope.run(function(done)
				return git.repo_root(mapped_path, done)
			end, prepare)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param on_done fun(result: { repo_path: string, local_branch: string }|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.checkout_pr(pr, on_done)
	local src_branch = pr.source.branch
	if src_branch == "" then
		on_done(nil, "PR source branch is missing")
		return
	end

	local scope = requests.new()

	local function checkout_repo(repo_path)
		local function finish(ok, err)
			on_done(ok and { repo_path = repo_path, local_branch = src_branch } or nil, err)
		end
		local function create_branch(err)
			if err then
				on_done(nil, err)
				return
			end
			scope.run(function(done)
				return git.checkout_new_branch(repo_path, src_branch, pr.source.commit_hash, done)
			end, finish)
		end
		scope.run(function(done)
			return git.rev_exists(repo_path, "refs/heads/" .. src_branch, done)
		end, function(exists)
			if exists then
				scope.run(function(done)
					return git.checkout_branch(repo_path, src_branch, done)
				end, finish)
				return
			end
			scope.run(function(done)
				return fetch_pr_refs(pr, repo_path, done)
			end, create_branch)
		end)
	end

	-- Prefer the checkout or worktree the user is currently in. Falling back to repo_config.paths
	-- keeps checkout working when Atlas is opened outside a matching repository.
	scope.run(function(done)
		return matching_root(nil, pr.repo_full_name, pr.link.html, done)
	end, function(repo_path)
		if repo_path then
			checkout_repo(repo_path)
			return
		end
		scope.run(function(done)
			return M.resolve_repo_path_for_pr(pr, { require_existing = true }, done)
		end, function(mapped_path, resolve_err)
			if not mapped_path then
				on_done(nil, resolve_err)
				return
			end
			scope.run(function(done)
				return git.repo_root(mapped_path, done)
			end, function(root)
				if not root then
					on_done(nil, string.format("mapped path is not a git repository: %s", mapped_path))
					return
				end
				checkout_repo(root)
			end)
		end)
	end)
	return scope
end

---@param repo_full_name string
---@param repo_url string|nil Web URL of the repository; one of the mapped checkout's remotes must match it
---@param on_done fun(root: string|nil, err: string|nil, remote: string|nil)
---@return { cancel: fun() }|nil
function M.resolve_repo_root(repo_full_name, repo_url, on_done)
	local path, err = resolve_repo_path(repo_full_name, { require_existing = true })
	if not path then
		on_done(nil, err)
		return nil
	end
	return matching_root(path, repo_full_name, repo_url, on_done)
end

---@param root string
---@param remote string
---@param branches { name: string, hash: string }[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(root, remote, branches, on_done)
	local hashes = {}
	for _, branch in ipairs(branches) do
		if branch.hash == "" then
			on_done(false, "The branch has no commit to load: " .. branch.name)
			return
		end

		table.insert(hashes, branch.hash)
	end

	local scope = requests.new()
	scope.run(function(done)
		return git.check_commits(root, hashes, done)
	end, function(exists, err)
		if not exists then
			on_done(false, err)
			return
		end

		local refs = {}
		for index, branch in ipairs(branches) do
			if not exists[index] then
				table.insert(refs, "refs/heads/" .. branch.name)
			end
		end

		if #refs == 0 then
			on_done(true, nil)
			return
		end

		scope.run(function(done)
			return git.fetch_refs(root, remote, refs, done)
		end, on_done)
	end)

	return scope
end

---@param root string
---@param remote string
---@param branch { name: string, hash: string }
---@param on_done fun(commits: AtlasGitCommit[]|nil, err: string|nil)
---@return AtlasRequestScope
function M.branch_history(root, remote, branch, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return M.fetch_commits(root, remote, { branch }, done)
	end, function(ok, err)
		if not ok then
			on_done(nil, err)
			return
		end

		scope.run(function(done)
			return git.branch_commits(root, branch.hash, done)
		end, on_done)
	end)

	return scope
end

---@param root string
---@param remote string
---@param name string Branch name
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.checkout_branch(root, remote, name, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return git.rev_exists(root, "refs/heads/" .. name, done)
	end, function(exists)
		if exists then
			scope.run(function(done)
				return git.checkout_branch(root, name, done)
			end, on_done)
			return
		end

		local remote_ref = "refs/remotes/" .. remote .. "/" .. name
		scope.run(function(done)
			return git.fetch_refs(root, remote, { "refs/heads/" .. name .. ":" .. remote_ref }, done)
		end, function(ok, err)
			if not ok then
				on_done(false, err)
				return
			end

			scope.run(function(done)
				return git.checkout_new_branch(root, name, remote_ref, done)
			end, on_done)
		end)
	end)

	return scope
end

return M
