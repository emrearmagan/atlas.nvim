local M = {}

local core_git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local CACHE_SEGMENTS = "atlas/worktrees"
local STALE_SECONDS = 7 * 24 * 60 * 60 -- one week
local MAX_SLUG_LENGTH = 60
local SHA_LENGTH = 12

---@param value any
---@return string
local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param path string
---@return string
local function normalize_separators(path)
	return (path:gsub("\\", "/"))
end

-- Last path segment, ignoring trailing separators. Kept free of vim.fn so it stays unit-testable.
---@param path string
---@return string
local function basename(path)
	local normalized = normalize_separators(trim(path)):gsub("/+$", "") -- remove trailing slashes
	return normalized:match("([^/]+)$") or normalized
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
	local real = vim.uv and vim.uv.fs_realpath and vim.uv.fs_realpath(value) or nil
	return (normalize_separators(real or value):gsub("/+$", ""))
end

---@return string
function M.cache_root()
	return join(vim.fn.stdpath("cache"), CACHE_SEGMENTS)
end

-- True only for directories strictly below the cache root. Everything Atlas is allowed to delete by
-- hand lives there; a user supplied `dir` never qualifies, so a failed removal cannot wipe it.
---@param dir string
---@return boolean
function M.is_cache_path(dir)
	local prefix = M.cache_root() .. "/"
	local value = normalize_separators(trim(dir)):gsub("/+$", "")
	return #value > #prefix and value:sub(1, #prefix) == prefix
end

---@class AtlasWorktreeContext
---@field repo_root string
---@field repo_full_name string|nil
---@field pr_id string|integer|nil
---@field head_sha string
---@field default string|nil Only populated when handed to a user supplied `dir` function.

-- Default location: <cache>/atlas/worktrees/<repo-slug>-<sha>
---@param ctx AtlasWorktreeContext
---@return string
function M.default_dir(ctx)
	local name = trim(ctx.repo_full_name)
	if name == "" then
		name = basename(ctx.repo_root)
	end
	-- These paths show up in pickers and statuslines, so prefer the pull request number over a
	-- hash. A worktree whose head moved is rebuilt by ensure, so the number stays unambiguous.
	local pr_id = trim(ctx.pr_id)
	local leaf = pr_id ~= "" and "pr-" .. slugify(pr_id) or trim(ctx.head_sha):sub(1, SHA_LENGTH)
	if leaf == "" then
		leaf = "head"
	end
	return join(M.cache_root(), slugify(name), leaf)
end

---@param cfg AtlasPullsDiffLspConfig|nil
---@return boolean ok
---@return string|nil err
function M.validate(cfg)
	if cfg == nil then
		return true, nil
	end
	if type(cfg) ~= "table" then
		return false, "diff.lsp must be a table"
	end
	if cfg.enabled ~= nil and type(cfg.enabled) ~= "boolean" then
		return false, "diff.lsp.enabled must be a boolean"
	end
	local dir = cfg.dir
	if dir ~= nil and type(dir) ~= "string" and type(dir) ~= "function" then
		return false, "diff.lsp.dir must be a string or a function"
	end
	if type(dir) == "string" and not is_absolute(dir) then
		return false, "diff.lsp.dir must be an absolute path"
	end
	if cfg.link ~= nil then
		if type(cfg.link) ~= "table" then
			return false, "diff.lsp.link must be a list of relative paths"
		end
		for _, entry in ipairs(cfg.link) do
			if type(entry) ~= "string" or trim(entry) == "" then
				return false, "diff.lsp.link entries must be non-empty strings"
			end
			local value = normalize_separators(trim(entry))
			if is_absolute(value) then
				return false, string.format("diff.lsp.link entry must be relative: %s", entry)
			end
			if value == ".." or value:find("^%.%./") or value:find("/%.%./") or value:find("/%.%.$") then
				return false, string.format("diff.lsp.link entry must not escape the repository: %s", entry)
			end
			if value == ".git" or value:find("^%.git/") then
				return false, "diff.lsp.link entry must not be .git"
			end
		end
	end
	return true, nil
end

-- Resolve where the worktree for `ctx` should live, honouring a user supplied override.
---@param ctx AtlasWorktreeContext
---@param cfg AtlasPullsDiffLspConfig|nil
---@return string|nil dir
---@return string|nil err
function M.resolve_dir(ctx, cfg)
	local ok, err = M.validate(cfg)
	if not ok then
		return nil, err
	end

	local default = M.default_dir(ctx)
	local override = cfg and cfg.dir or nil
	if override == nil then
		return default, nil
	end

	local resolved
	if type(override) == "function" then
		local argument = { default = default }
		for key, value in pairs(ctx) do
			argument[key] = value
		end
		local called, value = pcall(override, argument)
		if not called then
			return nil, "diff.lsp.dir raised an error: " .. tostring(value)
		end
		if value == nil or trim(value) == "" then
			return default, nil
		end
		if type(value) ~= "string" then
			return nil, "diff.lsp.dir must return a string or nil"
		end
		resolved = trim(value)
	else
		resolved = trim(override)
	end

	if not is_absolute(resolved) then
		return nil, string.format("diff.lsp.dir must be an absolute path: %s", resolved)
	end
	return (normalize_separators(resolved):gsub("/+$", "")), nil
end

-- Claims

---@type table<string, { repo_root: string }>
local claims = {}

---@param dir string
---@return boolean
function M.is_claimed(dir)
	return claims[dir] ~= nil
end

---@return string[]
function M.claimed_dirs()
	local dirs = {}
	for dir in pairs(claims) do
		table.insert(dirs, dir)
	end
	table.sort(dirs)
	return dirs
end

---@param dir string
function M.release(dir)
	claims[dir] = nil
end

-- A worktree is only shared sequentially: while a session holds one, the next session gets its own
-- suffixed directory. Sessions paint extmarks into these buffers with module level namespaces, so
-- two sessions sharing one real buffer would overwrite each other's overlays.
---@param ctx AtlasWorktreeContext
---@param cfg AtlasPullsDiffLspConfig|nil
---@return string|nil dir
---@return string|nil err
function M.claim(ctx, cfg)
	local base, err = M.resolve_dir(ctx, cfg)
	if not base then
		return nil, err
	end

	if not M.is_claimed(base) then
		claims[base] = { repo_root = ctx.repo_root }
		return base, nil
	end

	for index = 2, 99 do
		local candidate = string.format("%s-%d", base, index)
		if not M.is_claimed(candidate) then
			claims[candidate] = { repo_root = ctx.repo_root }
			return candidate, nil
		end
	end
	return nil, "too many active worktrees for " .. base
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
function M.parse_worktree_list(stdout)
	local paths = {}
	for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
		local path = line:match("^worktree%s+(.+)$")
		if path then
			table.insert(paths, trim(path))
		end
	end
	return paths
end

---@param on_done fun(dir: string|nil, err: string|nil)
local function new_operation(on_done)
	local op = { cancelled = false, finished = false, handle = nil }

	op.cancel = function()
		if op.cancelled or op.finished then
			return
		end
		op.cancelled = true
		if op.handle then
			pcall(op.handle.cancel)
			op.handle = nil
		end
	end

	---@param dir string|nil
	---@param err string|nil
	op.finish = function(dir, err)
		if op.cancelled or op.finished then
			return
		end
		op.finished = true
		op.handle = nil
		on_done(dir, err)
	end

	---@param args string[]
	---@param on_exit fun(res: vim.SystemCompleted)
	op.git = function(args, on_exit)
		if op.cancelled or op.finished then
			return
		end
		local ok, handle = pcall(core_git.run, args, { text = true }, function(res)
			if not op.cancelled and not op.finished then
				on_exit(res)
			end
		end)
		if ok and handle then
			op.handle = handle
			return
		end
		vim.schedule(function()
			op.finish(nil, ok and "Failed to start git" or tostring(handle))
		end)
	end

	return op
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
	if not M.is_cache_path(dir) then
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
		local relative = normalize_separators(trim(entry)):gsub("^/+", ""):gsub("/+$", "")
		local source = join(repo_root, relative)
		local target = join(dir, relative)
		if relative ~= "" and (directory_exists(source) or vim.uv.fs_stat(source)) and not vim.uv.fs_lstat(target) then
			local parent = target:match("^(.*)/[^/]+$")
			if parent and parent ~= "" then
				vim.fn.mkdir(parent, "p")
			end
			local ok, err = vim.uv.fs_symlink(source, target, { dir = true, junction = true })
			if not ok then
				logger.logwarn("worktree.link failed", { source = source, target = target, error = tostring(err) })
			end
		end
	end
end

---@param repo_root string
---@param dir string
---@param on_done fun(err: string|nil)|nil
---@return { cancel: fun() }|nil
function M.remove(repo_root, dir, on_done)
	on_done = on_done or function() end
	if trim(dir) == "" then
		on_done(nil)
		return nil
	end
	return core_git.run({ "-C", repo_root, "worktree", "remove", "--force", dir }, { text = true }, function(res)
		if res.code == 0 then
			on_done(nil)
			return
		end
		-- The worktree may already be gone or the metadata broken; clean up by hand, but only inside
		-- the cache root.
		local error_message = command_error(res, "Failed to remove worktree")
		local deleted = delete_owned(dir, error_message)
		core_git.run({ "-C", repo_root, "worktree", "prune" }, { text = true }, function()
			if deleted then
				logger.logwarn("worktree.remove fell back to manual delete", { dir = dir, error = error_message })
			end
			on_done(nil)
		end)
	end)
end

-- Give up a worktree. The claim is held until the directory is actually gone, so a session that
-- reopens the same commit meanwhile gets its own directory instead of racing the removal.
---@param repo_root string
---@param dir string
function M.discard(repo_root, dir)
	if not M.is_claimed(dir) then
		M.remove(repo_root, dir)
		return
	end
	M.remove(repo_root, dir, function()
		M.release(dir)
	end)
end

-- Remove every claimed worktree synchronously. Called on exit, where an async removal would never
-- get the chance to run; anything that still slips through is caught by prune on the next open.
---@param timeout_ms integer|nil
function M.shutdown(timeout_ms)
	local timeout = timeout_ms or 2000
	for dir, info in pairs(claims) do
		pcall(function()
			vim.system({ "git", "-C", info.repo_root, "worktree", "remove", "--force", dir }, { text = true })
				:wait(timeout)
		end)
		delete_owned(dir, "shutdown")
	end
	claims = {}
end

-- Best effort cleanup of directories left behind by a crash. Never touches claimed worktrees.
---@param repo_root string
function M.prune(repo_root)
	core_git.run({ "-C", repo_root, "worktree", "prune" }, { text = true }, function() end)

	local root = M.cache_root()
	if not directory_exists(root) then
		return
	end
	local now = os.time()

	---@param dir string
	local function remove_if_stale(dir)
		if M.is_claimed(dir) then
			return false
		end
		local stat = vim.uv.fs_stat(dir)
		local mtime = stat and stat.mtime and stat.mtime.sec or now
		if now - mtime <= STALE_SECONDS then
			return false
		end
		logger.loginfo("worktree.prune removing stale worktree", { dir = dir })
		vim.fn.delete(dir, "rf")
		return true
	end

	---@param dir string
	---@return string[]
	local function child_directories(dir)
		local scanner = vim.uv.fs_scandir(dir)
		local children = {}
		while scanner do
			local name, kind = vim.uv.fs_scandir_next(scanner)
			if not name then
				break
			end
			if kind == "directory" then
				table.insert(children, join(dir, name))
			end
		end
		return children
	end

	-- Worktrees live one level below the repository directory, as <repo>/<pr or sha>.
	for _, repo_dir in ipairs(child_directories(root)) do
		local children = child_directories(repo_dir)
		local removed = 0
		for _, dir in ipairs(children) do
			if remove_if_stale(dir) then
				removed = removed + 1
			end
		end
		if #children == 0 or removed == #children then
			vim.fn.delete(repo_dir, "d")
		end
	end
end

---@class AtlasWorktreeEnsureOptions
---@field repo_root string
---@field head_sha string
---@field dir string
---@field link string[]|nil

-- Create (or reuse) a detached worktree at `head_sha`. The caller must have fetched the ref first.
---@param opts AtlasWorktreeEnsureOptions
---@param on_done fun(dir: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.ensure(opts, on_done)
	local op = new_operation(on_done)
	local repo_root = trim(opts.repo_root)
	local head_sha = trim(opts.head_sha)
	local dir = trim(opts.dir)

	if repo_root == "" or head_sha == "" or dir == "" then
		vim.schedule(function()
			op.finish(nil, "Repository path, head revision, and worktree path are required")
		end)
		return op
	end

	local function succeed()
		apply_links(repo_root, dir, opts.link)
		op.finish(dir, nil)
	end

	local function create()
		local parent = dir:match("^(.*)/[^/]+$")
		if parent and parent ~= "" then
			vim.fn.mkdir(parent, "p")
		end
		op.git({ "-C", repo_root, "worktree", "add", "--detach", dir, head_sha }, function(res)
			if res.code ~= 0 then
				op.finish(nil, command_error(res, "Failed to create worktree"))
				return
			end
			logger.loginfo("worktree.ensure created", { dir = dir, head = head_sha })
			succeed()
		end)
	end

	local function recreate()
		M.remove(repo_root, dir, function()
			if op.cancelled or op.finished then
				return
			end
			create()
		end)
	end

	-- Reuse an existing worktree only when it already points at the same commit.
	local function reuse_or_recreate()
		op.git({ "-C", dir, "rev-parse", "HEAD" }, function(res)
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
		return op
	end

	-- The directory exists. Only a worktree registered to this repository may be reused or rebuilt
	-- in place. Anything else under the cache root is leftover junk we own; anything else elsewhere
	-- belongs to the user and is refused rather than deleted.
	op.git({ "-C", repo_root, "worktree", "list", "--porcelain" }, function(res)
		if res.code ~= 0 then
			op.finish(nil, command_error(res, "Failed to list worktrees"))
			return
		end
		local wanted = canonical(dir)
		for _, path in ipairs(M.parse_worktree_list(res.stdout)) do
			if canonical(path) == wanted then
				reuse_or_recreate()
				return
			end
		end
		if M.is_cache_path(dir) then
			recreate()
			return
		end
		op.finish(nil, string.format("worktree path exists and is not a worktree of %s: %s", repo_root, dir))
	end)

	return op
end

return M
