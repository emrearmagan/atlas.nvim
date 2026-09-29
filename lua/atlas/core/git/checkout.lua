local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")

local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

---@return AtlasGitTransport transport
local function configured_git_transport()
	return config.options.pulls.git_transport == "ssh" and "ssh" or "https"
end

local function star_count(s)
	local _, n = s:gsub("%*", "")
	return n
end

-- Split "workspace/seg" -> ws, seg. Returns nil if the key has extra slashes.
local function split_key(key)
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
---@param opts {require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
function M.resolve_repo_path(repo_paths, repo_name, opts)
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
	if not resolved or resolved == "" then
		local best
		for key, value in pairs(repo_paths) do
			local ws, seg = split_key(key)
			if ws == workspace and seg:find("*", 1, true) and value ~= "" then
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

	if not resolved or resolved == "" then
		return nil, string.format("no repo_paths mapping for '%s'", repo_name)
	end
	resolved = normalize_path(resolved)

	if opts.require_existing ~= false and vim.fn.isdirectory(resolved) ~= 1 then
		return nil, string.format("mapped path does not exist: %s", resolved)
	end
	return resolved, nil
end

---@param pr PullRequest
---@param opts {require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
function M.resolve_repo_path_for_pr(pr, opts)
	local repo_id = pr.repo_full_name
	if repo_id == "" then
		return nil, "missing PR repo_full_name"
	end

	local mapping = (config.options.pulls.repo_config or {}).paths or {}
	return M.resolve_repo_path(mapping, repo_id, opts)
end

---@param pr PullRequest
---@return string|nil base_revision
---@return string|nil head_revision
---@return string|nil err
function M.pr_diff_revisions(pr)
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
---@return string remote
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
	return "origin", nil
end

---@param pr PullRequest
---@param repo_path string
---@param on_done fun(err: string|nil)
---@param on_progress (fun(label: string, percent: integer))|nil
---@return { cancel: fun() }|nil
local function fetch_pr_refs(pr, repo_path, on_done, on_progress)
	local base_revision, head_revision, revision_err = M.pr_diff_revisions(pr)
	if not base_revision or not head_revision then
		on_done(revision_err)
		return nil
	end

	local scope = requests.new()
	local refs = {}
	local index = 0

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
			return git.fetch_refs(repo_path, ref.remote, { ref.ref }, done, on_progress)
		end, function(ok, err)
			if not ok then
				on_done(err)
				return
			end
			next_ref()
		end)
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
		if not exists[1] then
			local ref = fetch_ref(pr.destination)
			if ref ~= "" then
				refs[#refs + 1] = { remote = "origin", ref = ref }
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
				refs[#refs + 1] = { remote = remote, ref = ref }
			end
		end
		next_ref()
	end)
	return scope
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
	local cache_path = vim.fs.joinpath(vim.fn.stdpath("cache"), "atlas", "repos", target.host, repository)
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
			return fetch_pr_refs(pr, path, done, function(phase, percent)
				on_progress(progress_message("Fetching pull request refs", phase, percent))
			end)
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
				{ text = true },
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

---@param pr PullRequest
---@param on_done fun(root: string|nil)
---@return AtlasRequestScope
local function current_repo_path(pr, on_done)
	local scope = requests.new()
	local target = providers.resolve(pr.link.html)
	if not target then
		on_done(nil)
		return scope
	end
	scope.run(function(done)
		return git.repo_root(nil, done)
	end, function(root)
		if not root then
			on_done(nil)
			return
		end
		scope.run(function(done)
			return git.local_repository(root, done)
		end, function(current)
			local matches = current
				and current.provider == target.provider
				and current.host:lower() == target.host:lower()
				and tostring(current.repo_full_name):lower() == tostring(pr.repo_full_name):lower()
			on_done(matches and root or nil)
		end)
	end)
	return scope
end

---@param pr PullRequest
---@param preferred_root string|nil
---@param on_progress fun(message: string)
---@param on_done fun(source: AtlasDiffSource|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.prepare_diff(pr, preferred_root, on_progress, on_done)
	local base, head, revision_err = M.pr_diff_revisions(pr)
	if not base or not head then
		on_done(nil, revision_err)
		return nil
	end

	local scope = requests.new()
	local function prepare(repo_path)
		scope.run(function(done)
			return ensure_repository(pr, repo_path, on_progress, done)
		end, function(root, err)
			if not root then
				on_done(nil, err)
				return
			end
			on_done({ root = root, base_revision = base, head_revision = head }, nil)
		end)
	end
	if preferred_root then
		prepare(preferred_root)
		return scope
	end
	scope.run(function(done)
		return current_repo_path(pr, done)
	end, function(root)
		if root then
			prepare(root)
			return
		end
		local mapped_path = M.resolve_repo_path_for_pr(pr, { require_existing = true })
		if not mapped_path then
			prepare(nil)
			return
		end
		scope.run(function(done)
			return git.repo_root(mapped_path, done)
		end, prepare)
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

	local mapped_path, resolve_err = M.resolve_repo_path_for_pr(pr, {
		require_existing = true,
	})
	if not mapped_path then
		on_done(nil, resolve_err)
		return
	end

	local scope = requests.new()
	scope.run(function(done)
		return git.repo_root(mapped_path, done)
	end, function(repo_path)
		if not repo_path then
			on_done(nil, string.format("mapped path is not a git repository: %s", mapped_path))
			return
		end
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
	end)
	return scope
end

return M
