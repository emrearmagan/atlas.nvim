local git = require("atlas.core.git")

local M = {}

---@class AtlasCreateRemote
---@field name string
---@field url string
---@field target AtlasTarget|nil

---@class AtlasCreateBranchOption
---@field remote string
---@field branch string
---@field label string
---@field target AtlasTarget

---@param remote AtlasCreateRemote
---@param name string
---@return boolean
local function named(remote, name)
	return remote.name == name
end

---@param remotes AtlasCreateRemote[]
---@param name string
---@return AtlasCreateRemote|nil
local function find(remotes, name)
	for _, remote in ipairs(remotes) do
		if named(remote, name) then
			return remote
		end
	end
	return nil
end

---@param left AtlasTarget
---@param right AtlasTarget
---@return boolean
local function same_repository_host(left, right)
	return left.provider == right.provider and left.host == right.host
end

---@param remotes AtlasCreateRemote[]
---@param tracked string|nil The remote the current branch tracks.
---@return AtlasCreateRemote|nil, string|nil
function M.base_remote(remotes, tracked)
	if tracked and tracked ~= "" then
		local remote = find(remotes, tracked)
		if remote and remote.target then
			return remote
		end
	end
	local remote = git.select_base_remote(remotes)
	if remote then
		return remote
	end
	return nil, "No supported Git remote found"
end

---Whether the head lives in the base repository. A head without a supported target is treated as the same repository.
---@param head_target AtlasTarget|nil
---@param base_repo_slug string
---@return boolean
function M.same_repository(head_target, base_repo_slug)
	return not head_target or head_target.repo_full_name == base_repo_slug
end

---@param remotes AtlasCreateRemote[]
---@param pushed string|nil The remote the current branch is pushed to.
---@return AtlasCreateRemote|nil, string|nil
function M.head_remote(remotes, pushed)
	if pushed and pushed ~= "" then
		local remote = find(remotes, pushed)
		if remote then
			return remote
		end
	end
	local origin = find(remotes, "origin")
	if origin then
		return origin
	end
	if #remotes == 0 then
		return nil, "No Git remotes configured"
	end
	return remotes[1]
end

---@param head AtlasCreateRemote|nil
---@param base AtlasCreateRemote|nil
---@return string|nil
function M.validate(head, base)
	if not head or not base or not head.target or not base.target then
		return nil
	end
	if same_repository_host(head.target, base.target) then
		return nil
	end
	return string.format("Head remote '%s' and base remote '%s' point to different providers", head.name, base.name)
end

---@param remotes AtlasCreateRemote[]
---@param base AtlasCreateRemote
---@return AtlasCreateRemote[]
function M.compatible_remotes(remotes, base)
	local result = {}
	if not base.target then
		return result
	end
	for _, remote in ipairs(remotes) do
		if remote.target and same_repository_host(remote.target, base.target) then
			table.insert(result, remote)
		end
	end
	return result
end

---@param branches table<string, string[]>
---@param remotes AtlasCreateRemote[]
---@param head_remote string
---@param head_branch string
---@param head_target AtlasTarget|nil
---@return AtlasCreateBranchOption[]
function M.branch_options(branches, remotes, head_remote, head_branch, head_target)
	local options = {}
	for _, remote in ipairs(remotes) do
		local target = remote.target
		if target then
			for _, branch in ipairs(branches[remote.name] or {}) do
				local is_head = remote.name == head_remote
					and branch == head_branch
					and (head_target == nil or target.repo_full_name == head_target.repo_full_name)
				if not is_head then
					table.insert(options, {
						remote = remote.name,
						branch = branch,
						label = remote.name .. "/" .. branch,
						target = target,
					})
				end
			end
		end
	end
	return options
end

---@param branches string[]
---@param preferred string|nil
---@param head_branch string|nil
---@param same_repository boolean
---@return string|nil
function M.base_branch(branches, preferred, head_branch, same_repository)
	local available = {}
	for _, branch in ipairs(branches) do
		available[branch] = true
	end

	---@param branch string|nil
	---@return boolean
	local function usable(branch)
		return branch ~= nil and branch ~= "" and not (same_repository and branch == head_branch)
	end

	if preferred and available[preferred] and usable(preferred) then
		return preferred
	end
	for _, candidate in ipairs({ "main", "master", "dev", "develop" }) do
		if available[candidate] and usable(candidate) then
			return candidate
		end
	end
	for _, branch in ipairs(branches) do
		if usable(branch) then
			return branch
		end
	end
	return preferred
end

---@param options AtlasCreateBranchOption[]
---@param remote AtlasCreateRemote
---@param branch string
---@return AtlasCreateBranchOption[]
function M.ensure_branch_option(options, remote, branch)
	if branch == "" or not remote.target then
		return options
	end
	for _, option in ipairs(options) do
		if option.remote == remote.name and option.branch == branch then
			return options
		end
	end
	table.insert(options, 1, {
		remote = remote.name,
		branch = branch,
		label = remote.name .. "/" .. branch,
		target = remote.target,
	})
	return options
end

---@param base_repo_slug string
---@param head_repo_slug string|nil
---@param branch string
---@return string
function M.head_ref(base_repo_slug, head_repo_slug, branch)
	if not head_repo_slug or head_repo_slug == "" or head_repo_slug == base_repo_slug then
		return branch
	end
	local owner = head_repo_slug:match("^([^/]+)/")
	if not owner then
		return branch
	end
	return owner .. ":" .. branch
end

return M
