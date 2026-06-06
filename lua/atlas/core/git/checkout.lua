local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

local function star_count(s)
	local _, n = s:gsub("%*", "")
	return n
end

-- Split "workspace/seg" → ws, seg. Returns nil if the key has extra slashes.
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
	if type(pr) ~= "table" then
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
---@param repo_path string
---@param on_done fun(err: string|nil)
function M.fetch_pr_branches(pr, repo_path, on_done)
	local src_branch = tostring((pr.source or {}).branch or "")
	local dst_branch = tostring((pr.destination or {}).branch or "")

	local refs = { dst_branch }
	local pr_id = tostring(pr.id or "")
	-- GitHub exposes every PR (including those from forks) under refs/pull/<N>/head
	-- on the base repo's origin. Fetching by branch name fails for fork PRs because
	-- the branch lives on the contributor's fork, not on origin.
	if pr.provider == "github" and pr_id ~= "" and src_branch ~= "" then
		table.insert(refs, string.format("+refs/pull/%s/head:refs/remotes/origin/%s", pr_id, src_branch))
	else
		table.insert(refs, src_branch)
	end

	git.fetch_branches(repo_path, "origin", refs, function(ok, err)
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

		local fetch_refs = { src_branch }
		local pr_id = tostring(pr.id or "")
		if pr.provider == "github" and pr_id ~= "" then
			fetch_refs = { string.format("+refs/pull/%s/head:refs/remotes/origin/%s", pr_id, src_branch) }
		end

		git.fetch_branches(repo_path, "origin", fetch_refs, function(fetch_ok, ferr)
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
