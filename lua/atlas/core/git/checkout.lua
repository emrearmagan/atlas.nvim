local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

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
	local source = tostring(pr.source.local_ref or "")
	local destination = tostring(pr.destination.local_ref or "")
	if source == "" then
		local branch = tostring(pr.source.branch or "")
		source = branch ~= "" and "origin/" .. branch or ""
	end
	if destination == "" then
		local branch = tostring(pr.destination.branch or "")
		destination = branch ~= "" and "origin/" .. branch or ""
	end
	if source == "" or destination == "" then
		return nil, nil, "PR branch refs are missing"
	end
	return destination, source, nil
end

---@param ref PullsRef
---@return string remote
---@return string fetch_ref
local function fetch_target(ref)
	local remote = tostring(ref.fetch_remote or "")
	local fetch_ref = tostring(ref.fetch_ref or "")
	return remote ~= "" and remote or "origin", fetch_ref ~= "" and fetch_ref or tostring(ref.branch or "")
end

---@param pr PullRequest
---@param repo_path string
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
function M.fetch_pr_branches(pr, repo_path, on_done)
	local base_remote, base_ref = fetch_target(pr.destination)
	local head_remote, head_ref = fetch_target(pr.source)
	if base_ref == "" or head_ref == "" then
		local cancelled = false
		vim.schedule(function()
			if not cancelled then
				on_done("PR branch refs are missing")
			end
		end)
		return {
			cancel = function()
				cancelled = true
			end,
		}
	end

	if base_remote == head_remote then
		local refs = { base_ref }
		if head_ref ~= base_ref then
			table.insert(refs, head_ref)
		end
		return git.fetch_branches(repo_path, base_remote, refs, function(ok, err)
			if ok then
				on_done(nil)
			else
				on_done(err or "Failed to fetch pull request refs")
			end
		end)
	end

	local cancelled = false
	local current
	current = git.fetch_branches(repo_path, base_remote, { base_ref }, function(ok, err)
		current = nil
		if cancelled then
			return
		end
		if not ok then
			on_done(err or "Failed to fetch pull request base ref")
			return
		end
		current = git.fetch_branches(repo_path, head_remote, { head_ref }, function(head_ok, head_err)
			current = nil
			if not cancelled then
				if head_ok then
					on_done(nil)
				else
					on_done(head_err or "Failed to fetch pull request head ref")
				end
			end
		end)
	end)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
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

		M.fetch_pr_branches(pr, repo_path, function(ferr)
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
