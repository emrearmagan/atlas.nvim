local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local function expand_home(path)
	if type(path) ~= "string" then
		return path
	end
	if path:sub(1, 2) == "~/" then
		local home = vim.env.HOME or vim.fn.expand("~")
		return home .. path:sub(2)
	end
	return path
end

local function normalize_path(path)
	return vim.fn.fnamemodify(expand_home(path), ":p")
end

local function wildcard_count(value)
	if type(value) ~= "string" then
		return 0
	end
	local _, count = value:gsub("%*", "")
	return count
end

local function split_repo(full_repo_name)
	if type(full_repo_name) ~= "string" then
		return nil, nil
	end
	return full_repo_name:match("^([^/]+)/([^/]+)$")
end

local function is_exact_key(key)
	return type(key) == "string" and key:match("^[^/]+/[^/*]+$") ~= nil
end

local function is_wildcard_key(key)
	return type(key) == "string" and key:match("^[^/]+/%*$") ~= nil
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

	local wildcard_workspace_seen = {}

	for key, value in pairs(repo_paths) do
		if type(key) ~= "string" or type(value) ~= "string" then
			return false, "repo_paths keys and values must be strings"
		end

		local exact = is_exact_key(key)
		local wildcard = is_wildcard_key(key)
		if not exact and not wildcard then
			return false, string.format("invalid key '%s' (expected workspace/repo or workspace/*)", key)
		end

		local wc = wildcard_count(value)
		if exact and wc ~= 0 then
			return false, string.format("exact key '%s' must map to non-wildcard path", key)
		end

		if wildcard then
			if wc ~= 1 then
				return false, string.format("wildcard key '%s' must map to path with exactly one '*'", key)
			end

			local workspace = key:match("^([^/]+)/%*$")
			if wildcard_workspace_seen[workspace] then
				return false, string.format("multiple wildcard mappings for workspace '%s' are not allowed", workspace)
			end
			wildcard_workspace_seen[workspace] = true
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
	local require_git = opts.require_git ~= false
	local require_existing = opts.require_existing ~= false

	local ok, err = M.validate_repo_paths(repo_paths)
	if not ok then
		return nil, err
	end

	local workspace, repo = split_repo(repo_name)
	if not workspace or not repo then
		return nil, "invalid repository identifier (expected workspace/repo)"
	end

	local resolved = nil
	local exact = repo_paths[repo_name]
	if type(exact) == "string" and exact ~= "" then
		resolved = normalize_path(exact)
	else
		local wildcard = repo_paths[workspace .. "/*"]
		if type(wildcard) == "string" and wildcard ~= "" then
			resolved = normalize_path((wildcard:gsub("%*", repo, 1)))
		end
	end

	if type(resolved) ~= "string" or resolved == "" then
		return nil, string.format("no repo_paths mapping for '%s'", repo_name)
	end

	if require_existing and vim.fn.isdirectory(resolved) ~= 1 then
		return nil, string.format("mapped path does not exist: %s", resolved)
	end

	if require_git then
		if not git.is_inside_work_tree(resolved) then
			return nil, string.format("mapped path is not a git repository: %s", resolved)
		end
	end

	return resolved, nil
end

---@param pr PullRequest|nil
---@param opts {require_git: boolean|nil, require_existing: boolean|nil }
---@return string|nil repo_path
---@return string|nil err
function M.resolve_repo_path_for_pr(pr, opts)
	if type(pr) ~= "table" then
		return nil, "no PR selected"
	end

	local repo_id = tostring(pr.repo_full_name or "")
	if repo_id == "" then
		return nil, "missing PR repo_full_name"
	end

	local pulls_cfg = (config.options.pulls or {})
	local mapping = ((pulls_cfg.repo_config or {}).paths) or {}
	return M.resolve_repo_path(mapping, repo_id, opts)
end

---@param pr PullRequest
---@param repo_path string
---@param on_done fun(err: string|nil)
function M.fetch_pr_branches(pr, repo_path, on_done)
	local src_branch = tostring((pr.source or {}).branch or "")
	local dst_branch = tostring((pr.destination or {}).branch or "")

	git.fetch_branches(repo_path, "origin", { src_branch, dst_branch }, function(ok, err)
		on_done(ok and nil or err)
	end)
end

---@class CheckoutResult
---@field repo_path string
---@field local_branch string

---@param pr PullRequest|nil
---@param on_done fun(result: CheckoutResult|nil, err: string|nil)
function M.checkout_pr(pr, on_done)
	on_done = on_done or function() end

	if type(pr) ~= "table" then
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

	git.checkout_branch(repo_path, src_branch, function(ok)
		if ok then
			logger.loginfo("checkout.checkout_pr switched existing branch", {
				pr_id = pr.id,
				repo_path = repo_path,
				branch = src_branch,
			})
			on_done({ repo_path = repo_path, local_branch = src_branch }, nil)
			return
		end

		git.fetch_branches(repo_path, "origin", { src_branch }, function(fetch_ok, ferr)
			if not fetch_ok then
				logger.logerror("checkout.checkout_pr fetch failed", {
					pr_id = pr.id,
					repo_path = repo_path,
					branch = src_branch,
					error = ferr,
				})
				on_done(nil, ferr)
				return
			end

			git.checkout_remote_branch(repo_path, src_branch, "origin", function(create_ok, cerr)
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
