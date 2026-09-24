local config = require("atlas.config")
local git = require("atlas.core.git")
local checkout = require("atlas.core.git.checkout")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")

local M = {}

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
---@return string|nil root
---@return string|nil err
function M.resolve(repo)
	local paths = (config.options.pulls.repo_config or {}).paths or {}
	return checkout.resolve_repo_path(paths, repo.full_name, {
		require_existing = true,
		require_git = true,
	})
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

	local exists = git.check_commits(root, hashes)
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
	local remote = git.local_repository(root)
	local target = opts.repo_url and providers.resolve(opts.repo_url) or nil
	if
		not remote
		or not target
		or remote.provider ~= target.provider
		or remote.host:lower() ~= target.host:lower()
		or tostring(remote.repo_full_name):lower() ~= tostring(target.repo_full_name):lower()
	then
		on_done(false, "Branch commits are missing locally and origin does not match this repository")
		return
	end
	return git.fetch_refs(root, "origin", refs, on_done)
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
