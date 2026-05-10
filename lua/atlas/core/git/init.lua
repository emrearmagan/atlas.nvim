local M = {}

local function trim(s)
	if type(s) ~= "string" then
		return ""
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param cmd string[]
---@param cwd string
---@param on_done fun(res: vim.SystemCompleted)
local function run(cmd, cwd, on_done)
	vim.system(cmd, { cwd = cwd, text = true }, on_done)
end

---@return string
local function default_cwd()
	local buf_name = vim.api.nvim_buf_get_name(0)
	if type(buf_name) == "string" and buf_name ~= "" then
		local dir = vim.fn.fnamemodify(buf_name, ":h")
		if vim.fn.isdirectory(dir) == 1 then
			return dir
		end
	end
	return vim.fn.getcwd()
end

---@param cwd string|nil
---@return string|nil root, string|nil err
function M.repo_root(cwd)
	cwd = cwd or default_cwd()
	local res = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }):wait()
	if res.code ~= 0 then
		return nil, "Not in a git repository"
	end
	local root = trim(res.stdout)
	if root == "" then
		return nil, "Not in a git repository"
	end
	return root, nil
end

---@param root string
---@return string|nil branch, string|nil err
function M.current_branch(root)
	local res = vim.system({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait()
	if res.code ~= 0 then
		return nil, "Failed to detect current branch"
	end
	local branch = trim(res.stdout)
	if branch == "" or branch == "HEAD" then
		return nil, "Detached HEAD — checkout a branch first"
	end
	return branch, nil
end

---@param root string
---@param rev string
---@return boolean
function M.rev_exists(root, rev)
	if root == "" or rev == "" then
		return false
	end
	local res = vim.system({ "git", "-C", root, "rev-parse", "--verify", "--quiet", rev }, { text = true }):wait()
	return res.code == 0
end

---@param root string
---@param base string
---@param head string
---@return string
function M.commit_range(root, base, head)
	local remote_base = "origin/" .. base
	if M.rev_exists(root, remote_base) then
		return remote_base .. ".." .. head
	end
	if M.rev_exists(root, base) then
		return base .. ".." .. head
	end
	return head
end

---@param root string
---@param range string
---@return { hash: string, subject: string }[]
function M.commits_for_range(root, range)
	local res = vim.system({ "git", "-C", root, "log", "--reverse", "--format=%h %s", range }, { text = true }):wait()
	if res.code ~= 0 then
		return {}
	end

	local commits = {}
	for line in tostring(res.stdout or ""):gmatch("[^\r\n]+") do
		local hash, subject = line:match("^(%S+)%s+(.+)$")
		hash = trim(hash)
		subject = trim(subject)
		if hash ~= "" and subject ~= "" then
			table.insert(commits, { hash = hash, subject = subject })
		end
	end
	return commits
end

---@param root string
---@param remote string|nil  -- defaults to "origin"
---@return string|nil url, string|nil err
function M.remote_url(root, remote)
	remote = remote or "origin"
	local res = vim.system({ "git", "-C", root, "remote", "get-url", remote }, { text = true }):wait()
	if res.code ~= 0 then
		return nil, string.format("Remote '%s' is not configured", remote)
	end
	local url = trim(res.stdout)
	if url == "" then
		return nil, string.format("Remote '%s' has no URL", remote)
	end
	return url, nil
end

---@class AtlasGitRemoteInfo
---@field host string -- e.g. "github.com" / "bitbucket.org" / "gitlab.com"
---@field provider "github"|"bitbucket"|"gitlab"|"unknown"
---@field slug string -- "owner/repo" or nested "group/subgroup/repo" (without .git)
---@field owner string
---@field repo string
---@field url string -- original remote URL

---@param url string
---@return AtlasGitRemoteInfo|nil info, string|nil err
function M.parse_remote_url(url)
	if type(url) ~= "string" or url == "" then
		return nil, "Empty remote URL"
	end

	local host, path
	-- ssh form: git@github.com:owner/repo.git
	host, path = url:match("^[%w_-]+@([^:]+):(.+)$")
	if host == nil then
		-- https form: https://github.com/owner/repo(.git)
		host, path = url:match("^https?://[^/]-([^/@]+)/(.+)$")
		if host == nil then
			-- git:// or ssh://
			host, path = url:match("^[%w]+://[^/]-([^/@]+)/(.+)$")
		end
	end

	if host == nil or path == nil then
		return nil, string.format("Could not parse remote URL: %s", url)
	end

	path = path:gsub("%.git$", "")
	local owner, repo = path:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		return nil, string.format("Could not parse owner/repo from: %s", url)
	end

	local provider = "unknown"
	if host:find("github") then
		provider = "github"
	elseif host:find("bitbucket") then
		provider = "bitbucket"
	elseif host:find("gitlab") then
		provider = "gitlab"
	end

	return {
		host = host,
		provider = provider,
		slug = owner .. "/" .. repo,
		owner = owner,
		repo = repo,
		url = url,
	},
		nil
end

---@param root string
---@param remote string|nil
---@return string|nil branch, string|nil err
function M.default_branch(root, remote)
	remote = remote or "origin"

	local res = vim.system({ "git", "-C", root, "symbolic-ref", "refs/remotes/" .. remote .. "/HEAD" }, { text = true })
		:wait()
	if res.code == 0 then
		local ref = trim(res.stdout)
		local branch = ref:match("refs/remotes/[^/]+/(.+)$")
		if branch and branch ~= "" then
			return branch, nil
		end
	end

	res = vim.system({ "git", "-C", root, "ls-remote", "--symref", remote, "HEAD" }, { text = true }):wait()
	if res.code == 0 then
		local ref = res.stdout:match("ref: refs/heads/([^%s]+)%s+HEAD")
		if ref and ref ~= "" then
			return ref, nil
		end
	end

	return nil, "Could not determine default branch"
end

---@param root string
---@param remote string
---@return string[] branches
function M.list_remote_branches(root, remote)
	remote = remote or "origin"
	local res = vim.system({ "git", "-C", root, "branch", "-r", "--format=%(refname:short)" }, { text = true }):wait()
	if res.code ~= 0 then
		return {}
	end
	local prefix = remote .. "/"
	local out = {}
	local seen = {}
	for line in (res.stdout or ""):gmatch("[^\r\n]+") do
		local name = trim(line)
		if name ~= "" and name:sub(1, #prefix) == prefix then
			local short = name:sub(#prefix + 1)
			if short ~= "HEAD" and not seen[short] then
				seen[short] = true
				table.insert(out, short)
			end
		end
	end
	return out
end

---@param root string
---@param branch string
---@param remote string|nil
---@return boolean
function M.branch_exists_on_remote(root, branch, remote)
	remote = remote or "origin"
	local res = vim.system(
		{ "git", "-C", root, "ls-remote", "--exit-code", "--heads", remote, branch },
		{ text = true }
	)
		:wait()
	return res.code == 0
end

---@param root string
---@return boolean
function M.is_inside_work_tree(root)
	local res = vim.system({ "git", "-C", root, "rev-parse", "--is-inside-work-tree" }, { text = true }):wait()
	return res.code == 0
end

---@param root string
---@param remote string
---@param branches string[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.fetch_branches(root, remote, branches, on_done)
	local cmd = { "git", "fetch", remote }
	for _, branch in ipairs(branches) do
		table.insert(cmd, branch)
	end

	run(
		cmd,
		root,
		vim.schedule_wrap(function(res)
			if res.code ~= 0 then
				local err = trim(res.stderr)
				if err == "" then
					err = string.format("git fetch failed with code %d", res.code)
				end
				on_done(false, err)
				return
			end
			on_done(true, nil)
		end)
	)
end

---@param root string
---@param branch string
---@param on_done fun(ok: boolean, err: string|nil)
function M.checkout_branch(root, branch, on_done)
	run({ "git", "checkout", branch }, root, function(res)
		if res.code ~= 0 then
			local err = trim(res.stderr)
			if err == "" then
				err = "git checkout branch failed"
			end
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param root string
---@param branch string
---@param remote string
---@param on_done fun(ok: boolean, err: string|nil)
function M.checkout_remote_branch(root, branch, remote, on_done)
	run({ "git", "checkout", "-b", branch, remote .. "/" .. branch }, root, function(res)
		if res.code ~= 0 then
			local err = trim(res.stderr)
			if err == "" then
				err = "git checkout branch failed"
			end
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param root string
---@param branch string
---@param remote string|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.push_branch(root, branch, remote, on_done)
	remote = remote or "origin"
	run(
		{ "git", "-C", root, "push", "-u", remote, branch },
		root,
		vim.schedule_wrap(function(res)
			if res.code ~= 0 then
				local err = trim(res.stderr)
				if err == "" then
					err = string.format("git push failed with code %d", res.code)
				end
				on_done(false, err)
				return
			end
			on_done(true, nil)
		end)
	)
end

return M
