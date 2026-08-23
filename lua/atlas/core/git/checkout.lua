local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

---@return AtlasGitTransport transport
local function configured_git_transport()
	local value = ((config.options or {}).pulls or {}).git_transport
	return value == "https" and "https" or "ssh"
end

local function star_count(s)
	local _, n = s:gsub("%*", "")
	return n
end

-- Split "workspace/seg" -> ws, seg. Returns nil if the key has extra slashes.
local function split_key(key)
	if type(key) ~= "string" then
		return nil, nil
	end
	return key:match("^([^/]+)/([^/]+)$")
end

local function normalize_path(path)
	if path:sub(1, 2) == "~/" then
		path = (vim.env.HOME or vim.fn.expand("~")) .. path:sub(2)
	end
	return vim.fn.fnamemodify(path, ":p")
end

-- Turn a seg like "proj-*-v*" into a Lua pattern with one capture per `*`.
local function seg_to_pattern(seg)
	local escaped = seg:gsub(LUA_PATTERN_SPECIALS, "%%%0"):gsub("%*", "([^/]+)")
	return "^" .. escaped .. "$"
end

-- Replace each `*` in `value` with the next capture from `captures`.
local function apply_captures(value, captures)
	local idx = 0
	return (value:gsub("%*", function()
		idx = idx + 1
		return captures[idx] or ""
	end))
end

-- Pattern specificity: fewer `*` wins, then longer literal text, then alphabetical key.
local function more_specific(a, b)
	if a.stars ~= b.stars then
		return a.stars < b.stars
	end
	if a.lit ~= b.lit then
		return a.lit > b.lit
	end
	return a.key < b.key
end

---@param repo_paths table<string, string>|nil
---@return boolean ok
---@return string|nil err
function M.validate_repo_paths(repo_paths)
	if repo_paths == nil then
		return true, nil
	end
	if type(repo_paths) ~= "table" then
		return false, "repo_paths must be a table<string,string>"
	end

	for key, value in pairs(repo_paths) do
		if type(key) ~= "string" or type(value) ~= "string" then
			return false, "repo_paths keys and values must be strings"
		end
		local _, seg = split_key(key)
		if seg == nil then
			return false, string.format("invalid key '%s' (expected workspace/repo or workspace/<pattern with *>)", key)
		end
		if star_count(seg) ~= star_count(value) then
			return false, string.format("wildcard parity mismatch for '%s' → '%s'", key, value)
		end
	end

	return true, nil
end

---@param repo_paths table<string, string>
---@param repo_name string
---@param opts {require_git: boolean|nil, require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
function M.resolve_repo_path(repo_paths, repo_name, opts)
	opts = opts or {}

	local ok, err = M.validate_repo_paths(repo_paths)
	if not ok then
		return nil, err
	end

	local workspace, repo = repo_name:match("^([^/]+)/([^/]+)$")
	if not workspace then
		return nil, "invalid repository identifier (expected workspace/repo)"
	end

	-- Exact match wins over any wildcard.
	---@type string|nil
	local resolved = repo_paths[repo_name]
	if type(resolved) ~= "string" or resolved == "" then
		local best
		for key, value in pairs(repo_paths) do
			local ws, seg = split_key(key)
			if ws == workspace and seg and seg:find("*", 1, true) and type(value) == "string" and value ~= "" then
				local captures = { repo:match(seg_to_pattern(seg)) }
				if captures[1] then
					local stars = star_count(seg)
					local candidate = {
						key = key,
						stars = stars,
						lit = #seg - stars,
						value = apply_captures(value, captures),
					}
					if not best or more_specific(candidate, best) then
						best = candidate
					end
				end
			end
		end
		resolved = best and best.value or nil
	end

	if type(resolved) ~= "string" or resolved == "" then
		return nil, string.format("no repo_paths mapping for '%s'", repo_name)
	end
	resolved = normalize_path(resolved)

	if opts.require_existing ~= false and vim.fn.isdirectory(resolved) ~= 1 then
		return nil, string.format("mapped path does not exist: %s", resolved)
	end
	if opts.require_git ~= false and not git.is_inside_work_tree(resolved) then
		return nil, string.format("mapped path is not a git repository: %s", resolved)
	end
	return resolved, nil
end

---@param pr PullRequest|nil
---@param opts {require_git: boolean|nil, require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
function M.resolve_repo_path_for_pr(pr, opts)
	if pr == nil then
		return nil, "no PR selected"
	end

	local repo_id = tostring(pr.repo_full_name or "")
	if repo_id == "" then
		return nil, "missing PR repo_full_name"
	end

	local pulls_cfg = (config.options.pulls or {})
	local mapping = (pulls_cfg.repo_config or {}).paths or {}
	return M.resolve_repo_path(mapping, repo_id, opts)
end

---@param pr PullRequest
---@return string|nil base_revision
---@return string|nil head_revision
---@return string|nil err
function M.pr_diff_revisions(pr)
	local base = tostring(pr.destination.commit_hash or "")
	local head = tostring(pr.source.commit_hash or "")
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
	local remote_ref = tostring(ref.fetch_ref or "")
	if remote_ref == "" then
		local branch = tostring(ref.branch or "")
		remote_ref = branch ~= "" and "refs/heads/" .. branch or ""
	end
	return remote_ref
end

---@param ref PullsRef
---@param transport AtlasGitTransport
---@param provider string
---@return string remote
---@return string|nil err
local function source_remote(ref, transport, provider)
	if ref.https_url ~= nil or ref.ssh_url ~= nil then
		local selected = transport == "ssh" and ref.ssh_url or nil
		if transport == "https" then
			selected = ref.https_url
		end
		if type(selected) ~= "string" or selected == "" then
			return "", string.format("%s did not provide a %s Git remote URL", provider, transport)
		end
		return selected, nil
	end
	return "origin", nil
end

---@param on_done fun(err: string|nil)
---@param err string|nil
---@return { cancel: fun() }
local function schedule_result(on_done, err)
	local cancelled = false
	vim.schedule(function()
		if not cancelled then
			on_done(err)
		end
	end)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param repo_path string
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
function M.fetch_pr_refs(pr, repo_path, on_done)
	local base_revision, head_revision, revision_err = M.pr_diff_revisions(pr)
	if not base_revision or not head_revision then
		return schedule_result(on_done, revision_err)
	end
	local transport = configured_git_transport()
	local base_remote = "origin"
	local base_ref = fetch_ref(pr.destination)
	local head_remote, remote_err = source_remote(pr.source, transport, pr.provider)
	if remote_err then
		return schedule_result(on_done, remote_err)
	end
	local head_ref = fetch_ref(pr.source)
	local cancelled = false
	local current
	local fetch_err

	local function missing_commit()
		if not git.rev_exists(repo_path, base_revision) then
			return "Pull request base commit is unavailable: " .. base_revision
		end
		if not git.rev_exists(repo_path, head_revision) then
			return "Pull request head commit is unavailable: " .. head_revision
		end
	end

	local function finish()
		local missing = missing_commit()
		on_done(missing and (fetch_err and missing .. ": " .. fetch_err or missing) or nil)
	end

	local function fetch_head()
		if not missing_commit() or head_ref == "" then
			finish()
			return
		end

		current = git.fetch_refs(repo_path, head_remote, { head_ref }, function(ok, err)
			current = nil
			if cancelled then
				return
			end
			if not ok then
				fetch_err = err or "Failed to fetch pull request ref"
			end
			finish()
		end)
	end

	if not missing_commit() then
		return schedule_result(on_done, nil)
	end
	if base_ref == "" then
		fetch_head()
	else
		current = git.fetch_refs(repo_path, base_remote, { base_ref }, function(ok, err)
			current = nil
			if cancelled then
				return
			end
			if not ok then
				fetch_err = err or "Failed to fetch pull request ref"
			end
			fetch_head()
		end)
	end
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@return string|nil cache_path
---@return string|nil remote_url
local function cached_pr_repository(pr)
	local resolver = require("atlas.providers.resolve")
	local target = resolver.resolve(pr.link.html)
	if not target or target.domain ~= "pulls" or target.entity ~= "pr" then
		return nil, nil
	end
	---@cast target AtlasTarget
	local repository = pr.repo_full_name
	local transport = configured_git_transport()
	local cache_path =
		vim.fs.joinpath(vim.fn.stdpath("cache"), "atlas", "repos", target.provider, target.host, repository)
	local advertised = transport == "ssh" and pr.destination.ssh_url or nil
	if transport == "https" then
		advertised = pr.destination.https_url
	end
	if type(advertised) == "string" and advertised ~= "" then
		return cache_path, advertised
	end

	if transport == "ssh" then
		return cache_path, string.format("git@%s:%s.git", target.host, repository)
	end
	local base_url = resolver.base_url(target):gsub("/+$", "")
	return cache_path, string.format("%s/%s.git", base_url, repository)
end

local PR_CACHE_MAX_AGE = 7 * 24 * 60 * 60

---@param action string
---@param phase string
---@param percent integer
---@return string
local function progress_message(action, phase, percent)
	return string.format("%s...\n%s %d%% / 100%%", action, phase, percent)
end

local function clean_pr_cache()
	local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "atlas", "repos")
	for _, git_dir in ipairs(vim.fs.find(".git", { path = root, type = "directory", limit = math.huge })) do
		local last_fetch = vim.uv.fs_stat(vim.fs.joinpath(git_dir, "FETCH_HEAD")) or vim.uv.fs_stat(git_dir)
		if last_fetch and os.time() - last_fetch.mtime.sec > PR_CACHE_MAX_AGE then
			vim.fn.delete(vim.fs.dirname(git_dir), "rf")
		end
	end
end

---@param pr PullRequest
---@param repo_path string|nil
---@param on_progress fun(message: string)
---@param on_done fun(repo_path: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.ensure_pr_repository(pr, repo_path, on_progress, on_done)
	local cached = repo_path == nil
	local current
	local cancelled = false
	local handle = {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}

	---@param path string
	local function fetch(path)
		on_progress("Fetching pull request refs...")
		current = M.fetch_pr_refs(pr, path, function(err)
			current = nil
			if cancelled then
				return
			end
			if err then
				on_done(nil, err)
				return
			end
			if cached then
				clean_pr_cache()
			end
			on_done(path, nil)
		end)
	end

	if repo_path then
		fetch(repo_path)
		return handle
	end

	local path, clone_url = cached_pr_repository(pr)
	if not path or not clone_url then
		on_done(nil, "Unable to determine the pull request repository")
		return nil
	end
	if git.is_inside_work_tree(path) then
		fetch(path)
		return handle
	end

	if vim.fn.isdirectory(path) == 1 then
		vim.fn.delete(path, "rf")
	end
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	on_progress("Cloning repository...")
	-- Leave the cache without a checkout; Git loads trees and blobs when a diff needs them.
	current = git.run({
		"clone",
		"--progress",
		"--filter=tree:0",
		"--no-checkout",
		"--single-branch",
		"--no-tags",
		clone_url,
		path,
	}, { text = true }, function(result)
		current = nil
		if cancelled then
			return
		end
		if result.code ~= 0 then
			vim.fn.delete(path, "rf")
			local err = vim.trim(tostring(result.stderr or ""))
			on_done(nil, err ~= "" and err or "Unable to clone pull request repository")
			return
		end
		fetch(path)
	end, function(phase, percent)
		on_progress(progress_message("Cloning repository", phase, percent))
	end)

	return handle
end

---@class CheckoutResult
---@field repo_path string
---@field local_branch string

---@param pr PullRequest|nil
---@param on_done fun(result: CheckoutResult|nil, err: string|nil)
function M.checkout_pr(pr, on_done)
	on_done = on_done or function() end

	if pr == nil then
		on_done(nil, "no PR selected")
		return
	end

	local src_branch = tostring(pr.source.branch or "")
	if src_branch == "" then
		on_done(nil, "PR source branch is missing")
		return
	end

	local repo_path, resolve_err = M.resolve_repo_path_for_pr(pr, {
		require_git = true,
		require_existing = true,
	})
	if not repo_path then
		on_done(nil, resolve_err)
		return
	end

	git.checkout_branch(repo_path, src_branch, function(ok, checkout_err)
		if ok then
			logger.loginfo("checkout.checkout_pr switched existing branch", {
				pr_id = pr.id,
				repo_path = repo_path,
				branch = src_branch,
			})
			on_done({ repo_path = repo_path, local_branch = src_branch }, nil)
			return
		end
		if git.rev_exists(repo_path, "refs/heads/" .. src_branch) then
			local err = checkout_err or "Unable to switch to the existing branch"
			logger.logerror("checkout.checkout_pr switch existing branch failed", {
				pr_id = pr.id,
				repo_path = repo_path,
				branch = src_branch,
				error = err,
			})
			on_done(nil, err)
			return
		end

		M.fetch_pr_refs(pr, repo_path, function(ferr)
			if ferr then
				logger.logerror("checkout.checkout_pr fetch failed", {
					pr_id = pr.id,
					repo_path = repo_path,
					branch = src_branch,
					error = ferr,
				})
				on_done(nil, ferr)
				return
			end

			local _, start_point, revision_err = M.pr_diff_revisions(pr)
			if not start_point then
				on_done(nil, revision_err)
				return
			end
			git.checkout_new_branch(repo_path, src_branch, start_point, function(create_ok, cerr)
				if not create_ok then
					logger.logerror("checkout.checkout_pr create branch failed", {
						pr_id = pr.id,
						repo_path = repo_path,
						branch = src_branch,
						error = cerr,
					})
					on_done(nil, cerr)
					return
				end

				logger.loginfo("checkout.checkout_pr created and switched branch", {
					pr_id = pr.id,
					repo_path = repo_path,
					branch = src_branch,
				})

				on_done({ repo_path = repo_path, local_branch = src_branch }, nil)
			end)
		end)
	end)
end
return M
