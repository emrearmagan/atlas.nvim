local config = require("atlas.config")
local git = require("atlas.core.git")
local checkout = require("atlas.core.git.checkout")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")

local M = {}

---@param remote_url string|nil
---@param repo_url string|nil
---@return boolean
local function matches_remote(remote_url, repo_url)
	local remote = remote_url and git.parse_remote_url(remote_url) or nil
	local target = repo_url and providers.resolve(repo_url) or nil
	return remote ~= nil
		and target ~= nil
		and remote.provider == target.provider
		and remote.host:lower() == target.host:lower()
		and tostring(remote.repo_full_name):lower() == tostring(target.repo_full_name):lower()
end

---@class RepositoryBranchCommit
---@field hash string
---@field parent string|nil
---@field message string
---@field author string
---@field date string

---@param output string
---@return RepositoryBranchCommit[]
local function parse_commits(output)
	local fields = vim.split(output, "\0", { plain = true })
	local commits = {}
	for index = 1, #fields - 4, 5 do
		table.insert(commits, {
			hash = fields[index],
			parent = fields[index + 1]:match("^%S+"),
			author = fields[index + 2],
			date = fields[index + 3],
			message = fields[index + 4],
		})
	end
	return commits
end

---@param repo AtlasRepository
---@param on_done fun(root: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.resolve(repo, on_done)
	local paths = (config.options.pulls.repo_config or {}).paths or {}
	local path, err = checkout.resolve_repo_path(paths, repo.full_name, {
		require_existing = true,
	})
	if not path then
		on_done(nil, err)
		return nil
	end
	return git.repo_root(path, on_done)
end

---@param root string
---@param branches AtlasRepositoryBranch[]
---@param opts { repo_url: string|nil }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(root, branches, opts, on_done)
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
			return git.remote_url(root, "origin", done)
		end, function(remote)
			if not matches_remote(remote, opts.repo_url) then
				on_done(false, "Branch commits are missing locally and origin does not match this repository")
				return
			end
			scope.run(function(done)
				return git.fetch_refs(root, "origin", refs, done)
			end, on_done)
		end)
	end)
	return scope
end

---@param root string
---@param branch AtlasRepositoryBranch
---@param opts { repo_url: string|nil }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.checkout(root, branch, opts, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return git.rev_exists(root, "refs/heads/" .. branch.name, done)
	end, function(exists)
		if exists then
			scope.run(function(done)
				return git.checkout_branch(root, branch.name, done)
			end, on_done)
			return
		end
		scope.run(function(done)
			return git.remote_url(root, "origin", done)
		end, function(remote)
			if not matches_remote(remote, opts.repo_url) then
				on_done(false, "Cannot fetch branch: origin does not match this repository")
				return
			end
			local remote_ref = "refs/remotes/origin/" .. branch.name
			scope.run(function(done)
				return git.fetch_refs(root, "origin", { "refs/heads/" .. branch.name .. ":" .. remote_ref }, done)
			end, function(ok, err)
				if not ok then
					on_done(false, err)
					return
				end
				scope.run(function(done)
					return git.checkout_new_branch(root, branch.name, remote_ref, done)
				end, on_done)
			end)
		end)
	end)
	return scope
end

---@param root string
---@param branch AtlasRepositoryBranch
---@param opts { repo_url: string|nil }
---@param on_done fun(commits: RepositoryBranchCommit[]|nil, err: string|nil)
---@return AtlasRequestScope
function M.load(root, branch, opts, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return M.fetch(root, { branch }, opts, done)
	end, function(ok, err)
		if not ok then
			on_done(nil, err)
			return
		end
		scope.run(function(done)
			return git.run({
				"log",
				"--no-show-signature",
				"--no-color",
				"-z",
				"--format=%H%x00%P%x00%an%x00%cI%x00%B",
				"--end-of-options",
				branch.hash,
				"--",
			}, { cwd = root, text = false }, done)
		end, function(result)
			if result.code ~= 0 then
				local message = vim.trim(result.stderr or "")
				on_done(nil, message ~= "" and message or "Failed to load branch commits")
				return
			end
			on_done(parse_commits(result.stdout or ""), nil)
		end)
	end)
	return scope
end

return M
