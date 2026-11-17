local M = {}

local core_git = require("atlas.core.git")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")

local CACHE_SEGMENTS = "atlas/worktrees"
local STALE_SECONDS = 7 * 24 * 60 * 60 -- one week
local MAX_SLUG_LENGTH = 60
local SHA_LENGTH = 12

---@param value any
---@return string
local function trim(value)
	return vim.trim(tostring(value or ""))
end

---@param path string
---@return string
local function normalize_separators(path)
	return (path:gsub("\\", "/"))
end

---@param value string
---@return string
local function slugify(value)
	-- "My Weird / Path" -> "my-weird-path"
	local slug = normalize_separators(trim(value)):lower():gsub("[^%w%-_]+", "-"):gsub("%-+", "-")
	slug = slug:gsub("^%-", ""):gsub("%-$", "") -- remove trailing hyphens, both sides
	if #slug > MAX_SLUG_LENGTH then
		slug = slug:sub(1, MAX_SLUG_LENGTH):gsub("%-$", "")
	end
	return slug ~= "" and slug or "repo"
end

---@param path string
---@return boolean
local function is_absolute(path)
	local normalized = normalize_separators(path)
	return normalized:sub(1, 1) == "/" or normalized:match("^%a:/") ~= nil
end

---@param ... string
---@return string
local function join(...)
	local parts = {}
	for _, part in ipairs({ ... }) do
		local value = normalize_separators(tostring(part or "")):gsub("/+$", "")
		if value ~= "" then
			table.insert(parts, value)
		end
	end
	return table.concat(parts, "/")
end

-- Canonical form for path comparison: symlinks resolved when the path exists, separators
-- normalized, trailing separators dropped.
---@param path string
---@return string
local function canonical(path)
	local value = trim(path)
	local real = vim.uv.fs_realpath(value)
	return (normalize_separators(real or value):gsub("/+$", ""))
end

---@return string
local function cache_root()
	return join(vim.fn.stdpath("cache"), CACHE_SEGMENTS)
end

-- True only for directories strictly below the cache root. Everything Atlas is allowed to delete by
-- hand lives there; a user supplied `dir` never qualifies, so a failed removal cannot wipe it.
---@param dir string
---@return boolean
local function is_cache_path(dir)
	local prefix = cache_root() .. "/"
	local value = normalize_separators(trim(dir)):gsub("/+$", "")
	return #value > #prefix and value:sub(1, #prefix) == prefix
end

---@class AtlasWorktreeContext
---@field dir string
---@field repo_root string
---@field repo_full_name string|nil
---@field pr_id string|integer|nil
---@field head_sha string

-- Default location: <cache>/atlas/worktrees/<repo>/pr-<id>, or <repo>/<sha> without a PR.
---@param repo_root string
---@param head_sha string
---@param pr PullRequest|nil
---@return string
local function default_dir(repo_root, head_sha, pr)
	local name = trim(pr and pr.repo_full_name)
	if name == "" then
		local root = normalize_separators(trim(repo_root)):gsub("/+$", "")
		name = vim.fs.basename(root)
	end
	-- These paths show up in pickers and statuslines, so prefer the pull request number over a
	-- hash. A worktree whose head moved is rebuilt by ensure, so the number stays unambiguous.
	local pr_id = trim(pr and pr.id)
	local leaf = pr_id ~= "" and "pr-" .. slugify(pr_id) or trim(head_sha):sub(1, SHA_LENGTH)
	if leaf == "" then
		leaf = "head"
	end
	return join(cache_root(), slugify(name), leaf)
end

---@param cfg AtlasPullsWorktreeConfig|nil
---@return boolean ok
---@return string|nil err
function M.validate(cfg)
	if cfg == nil then
		return true, nil
	end
	if type(cfg) ~= "table" then
		return false, "worktree must be a table"
	end
	local dir = cfg.dir
	if dir ~= nil and type(dir) ~= "string" and type(dir) ~= "function" then
		return false, "worktree.dir must be a string or a function"
	end
	if type(dir) == "string" and not is_absolute(dir) then
		return false, "worktree.dir must be an absolute path"
	end
	if cfg.on_create ~= nil and type(cfg.on_create) ~= "function" then
		return false, "worktree.on_create must be a function"
	end
	if cfg.link ~= nil then
		if type(cfg.link) ~= "table" then
			return false, "worktree.link must be a list of relative paths"
		end
		for _, entry in ipairs(cfg.link) do
			if type(entry) ~= "string" or trim(entry) == "" then
				return false, "worktree.link entries must be non-empty strings"
			end
			local value = normalize_separators(trim(entry))
			if is_absolute(value) then
				return false, string.format("worktree.link entry must be relative: %s", entry)
			end
			if value == ".." or value:find("^%.%./") or value:find("/%.%./") or value:find("/%.%.$") then
				return false, string.format("worktree.link entry must not escape the repository: %s", entry)
			end
			if value == ".git" or value:find("^%.git/") then
				return false, "worktree.link entry must not be .git"
			end
		end
	end
	return true, nil
end

-- Resolve where the worktree for `ctx` should live, honouring a user supplied override.
---@param ctx AtlasWorktreeContext
---@param cfg AtlasPullsWorktreeConfig|nil
---@return string|nil dir
---@return string|nil err
local function resolve_dir(ctx, cfg)
	local ok, err = M.validate(cfg)
	if not ok then
		return nil, err
	end

	local override = cfg and cfg.dir or nil
	if override == nil then
		return ctx.dir, nil
	end

	local resolved
	if type(override) == "function" then
		local called, value = pcall(override, vim.deepcopy(ctx))
		if not called then
			return nil, "worktree.dir raised an error: " .. tostring(value)
		end
		if value == nil or trim(value) == "" then
			return ctx.dir, nil
		end
		if type(value) ~= "string" then
			return nil, "worktree.dir must return a string or nil"
		end
		resolved = trim(value)
	else
		resolved = trim(override)
	end

	if not is_absolute(resolved) then
		return nil, string.format("worktree.dir must be an absolute path: %s", resolved)
	end
	return (normalize_separators(resolved):gsub("/+$", "")), nil
end

-- Claims

---@type table<string, { repo_root: string }>
local claims = {}

---@param dir string
---@return boolean
local function is_claimed(dir)
	return claims[dir] ~= nil
end

---@param dir string
local function release(dir)
	claims[dir] = nil
end

-- A worktree is only shared sequentially: while a session holds one, the next session gets its own
-- suffixed directory. Sessions paint extmarks into these buffers with module level namespaces, so
-- two sessions sharing one real buffer would overwrite each other's overlays.
---@param repo_root string
---@param head_sha string
---@param pr PullRequest|nil
---@param cfg AtlasPullsWorktreeConfig|nil
---@return AtlasWorktreeContext|nil ctx
---@return string|nil err
function M.claim(repo_root, head_sha, pr, cfg)
	---@type AtlasWorktreeContext
	local ctx = {
		dir = default_dir(repo_root, head_sha, pr),
		repo_root = repo_root,
		repo_full_name = pr and pr.repo_full_name,
		pr_id = pr and pr.id,
		head_sha = head_sha,
	}
	local base, err = resolve_dir(ctx, cfg)
	if not base then
		return nil, err
	end

	local candidate, index = base, 1
	while is_claimed(candidate) do
		index = index + 1
		candidate = string.format("%s-%d", base, index)
	end
	claims[candidate] = { repo_root = repo_root }
	ctx.dir = candidate
	return ctx, nil
end

-- Async helpers

---@param res vim.SystemCompleted
---@param fallback string
---@return string
local function command_error(res, fallback)
	local message = trim(res.stderr)
	if message ~= "" then
		return message
	end

	return string.format("%s (exit code %d)", fallback, res.code)
end

-- Paths from `git worktree list --porcelain`, in the order git prints them.
---@param stdout string|nil
---@return string[]
local function parse_worktree_list(stdout)
	local paths = {}
	for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
		local path = line:match("^worktree%s+(.+)$")
		if path then
			table.insert(paths, trim(path))
		end
	end
	return paths
end

---@param dir string
---@return boolean
local function directory_exists(dir)
	return vim.fn.isdirectory(dir) == 1
end

-- Recursive delete, restricted to the cache root. Anything else is left alone and reported, since
-- a user supplied `dir` may point at a directory that was never ours.
---@param dir string
---@param reason string
---@return boolean deleted
local function delete_owned(dir, reason)
	if not directory_exists(dir) then
		return true
	end
	if not is_cache_path(dir) then
		logger.logwarn("worktree refusing to delete outside the cache root", { dir = dir, reason = reason })
		return false
	end
	vim.fn.delete(dir, "rf")
	return true
end

-- Symlink dependency directories from the main checkout so language servers can resolve them.
-- Failures are never fatal: a worktree without node_modules still gives useful navigation.
---@param repo_root string
---@param dir string
---@param link string[]|nil
local function apply_links(repo_root, dir, link)
	for _, entry in ipairs(link or {}) do
		local source = join(repo_root, trim(entry))
		local target = join(dir, trim(entry))
		if vim.uv.fs_stat(source) and not vim.uv.fs_lstat(target) then
			vim.fn.mkdir(vim.fs.dirname(target), "p")
			local ok, err = vim.uv.fs_symlink(source, target, { dir = true, junction = true })
			if not ok then
				logger.logwarn("worktree.link failed", { source = source, target = target, error = tostring(err) })
			end
		end
	end
end

---@param repo_root string
---@param dir string
---@return string[]
local function remove_args(repo_root, dir)
	local args = { "-C", repo_root, "worktree", "remove", "--force", dir }
	-- Interrupted checkouts leave Git's "initializing" lock. Only force-unlock our cache worktrees.
	if is_cache_path(dir) then
		table.insert(args, #args, "--force")
	end
	return args
end

---@param repo_root string
---@param dir string
---@param on_done fun()|nil
---@return { cancel: fun() }|nil
local function remove(repo_root, dir, on_done)
	on_done = on_done or function() end
	if trim(dir) == "" then
		on_done()
		return nil
	end
	local scope = requests.new()
	scope.run(function(done)
		return core_git.run(remove_args(repo_root, dir), { text = true }, done)
	end, function(res)
		if res.code == 0 then
			on_done()
			return
		end
		-- The worktree may already be gone or the metadata broken; clean up by hand, but only inside
		-- the cache root.
		local error_message = command_error(res, "Failed to remove worktree")
		local deleted = delete_owned(dir, error_message)
		scope.run(function(done)
			return core_git.run({ "-C", repo_root, "worktree", "prune" }, { text = true }, done)
		end, function()
			if deleted then
				logger.logwarn("worktree.remove fell back to manual delete", { dir = dir, error = error_message })
			end
			on_done()
		end)
	end)
	return scope
end

-- Give up a worktree. The claim is held until the directory is actually gone, so a session that
-- reopens the same commit meanwhile gets its own directory instead of racing the removal.
---@param repo_root string
---@param dir string
---@return { cancel: fun() }|nil
function M.discard(repo_root, dir)
	if not is_claimed(dir) then
		return remove(repo_root, dir)
	end
	return remove(repo_root, dir, function()
		release(dir)
	end)
end

-- Best-effort cleanup: detached Git processes can finish after Neovim exits.
function M.shutdown()
	for dir, info in pairs(claims) do
		pcall(function()
			local args = vim.list_extend({ "git" }, remove_args(info.repo_root, dir))
			vim.system(args, { text = true, detach = true })
		end)
	end
	claims = {}
end

---@param dir string
---@return string|nil
local function git_dir(dir)
	local file = join(dir, ".git")
	if vim.fn.filereadable(file) == 0 then
		return nil
	end
	local path = (vim.fn.readfile(file, "", 1)[1] or ""):match("^gitdir:%s*(.-)%s*$")
	if not path then
		return nil
	end
	if not is_absolute(path) then
		path = join(dir, path)
	end
	return path:match("^(.*)/worktrees/[^/]+$")
end

---@param dir string
---@param now integer
---@return boolean
local function is_stale(dir, now)
	local stat = vim.uv.fs_stat(dir)
	return not is_claimed(dir) and stat ~= nil and now - stat.mtime.sec > STALE_SECONDS
end

function M.prune()
	local root = cache_root()
	if not directory_exists(root) then
		return
	end
	local now = os.time()

	for repo, kind in vim.fs.dir(root) do
		if kind == "directory" then
			local repo_dir = join(root, repo)
			for name, child_kind in vim.fs.dir(repo_dir) do
				local dir = join(repo_dir, name)
				if child_kind == "directory" and is_stale(dir, now) then
					logger.loginfo("worktree.prune removing stale worktree", { dir = dir })
					local repository = git_dir(dir)
					if repository and directory_exists(repository) then
						remove(repository, dir, function()
							vim.fn.delete(repo_dir, "d")
						end)
					else
						delete_owned(dir, "stale worktree without a repository")
					end
				end
			end
			vim.fn.delete(repo_dir, "d")
		end
	end
end

-- Create (or reuse) a detached worktree at `ctx.head_sha`. The caller must have fetched the ref first.
---@param ctx AtlasWorktreeContext
---@param cfg AtlasPullsWorktreeConfig|nil
---@param on_done fun(dir: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.ensure(ctx, cfg, on_done)
	local scope = requests.new()
	local repo_root = trim(ctx.repo_root)
	local head_sha = trim(ctx.head_sha)
	local dir = trim(ctx.dir)
	cfg = cfg or {}

	if repo_root == "" or head_sha == "" or dir == "" then
		on_done(nil, "Repository path, head revision, and worktree path are required")
		return scope
	end

	---@param created boolean|nil
	local function succeed(created)
		apply_links(repo_root, dir, cfg.link)
		if not created or not cfg.on_create then
			on_done(dir, nil)
			return
		end

		scope.run(function(done)
			---@type AtlasConsoleOutput|nil
			local output
			local ok, err = pcall(cfg.on_create, vim.deepcopy(ctx), function(result)
				local code = type(result) == "table" and result.code or 0
				if output then
					output:finish(code)
				end
				if code ~= 0 then
					notify.warn(
						string.format("worktree.on_create failed with exit code %d, see :Atlas console", code),
						{ vim_notify = true }
					)
				end
				vim.schedule(done)
			end, function(text)
				if not output then
					local console = require("atlas.ui.console")
					output = console.start("Preparing worktree", dir)
					console.open(false)
				end
				output:write(text)
			end)
			if not ok then
				if output then
					output:finish(1)
				end
				notify.warn("worktree.on_create raised an error: " .. tostring(err), { vim_notify = true })
				done()
			end
		end, function()
			on_done(dir, nil)
		end)
	end

	local function create()
		vim.fn.mkdir(vim.fs.dirname(dir), "p")
		local args = { "-C", repo_root, "worktree", "add", "--force", "--detach", dir, head_sha }
		if is_cache_path(dir) then
			table.insert(args, 5, "--force")
		end
		scope.run(function(done)
			return core_git.run(args, { text = true, console = true }, done)
		end, function(res)
			if res.code ~= 0 then
				on_done(nil, command_error(res, "Failed to create worktree"))
				return
			end
			logger.loginfo("worktree.ensure created", { dir = dir, head = head_sha })
			succeed(true)
		end)
	end

	local function recreate()
		scope.run(function(done)
			return remove(repo_root, dir, done)
		end, create)
	end

	-- Reuse an existing worktree only when it already points at the same commit.
	local function reuse_or_recreate()
		scope.run(function(done)
			return core_git.run({ "-C", dir, "rev-parse", "HEAD" }, { text = true }, done)
		end, function(res)
			local actual = trim(res.stdout)
			if res.code == 0 and actual ~= "" and actual:sub(1, #head_sha) == head_sha then
				logger.loginfo("worktree.ensure reused", { dir = dir, head = head_sha })
				succeed()
				return
			end
			recreate()
		end)
	end

	if not directory_exists(dir) then
		create()
		return scope
	end

	-- The directory exists. Only a worktree registered to this repository may be reused or rebuilt
	-- in place. Anything else under the cache root is leftover junk we own; anything else elsewhere
	-- belongs to the user and is refused rather than deleted.
	scope.run(function(done)
		return core_git.run({ "-C", repo_root, "worktree", "list", "--porcelain" }, { text = true }, done)
	end, function(res)
		if res.code ~= 0 then
			on_done(nil, command_error(res, "Failed to list worktrees"))
			return
		end
		local wanted = canonical(dir)
		for _, path in ipairs(parse_worktree_list(res.stdout)) do
			if canonical(path) == wanted then
				reuse_or_recreate()
				return
			end
		end
		if is_cache_path(dir) then
			recreate()
			return
		end
		on_done(nil, string.format("worktree path exists and is not a worktree of %s: %s", repo_root, dir))
	end)

	return scope
end

return M
