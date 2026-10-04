local M = {}

local logger = require("atlas.core.logger")
local providers = require("atlas.providers")
local requests = require("atlas.core.requests")

local function trim(value)
	return vim.trim(value or "")
end

local function redact(value)
	return tostring(value or ""):gsub("(%a[%w+.-]*://)[^/@%s]+@", "%1***@")
end

---@param res vim.SystemCompleted
---@param context table
local function log_failure(res, context)
	if res.code == 0 then
		return
	end
	context.code = res.code
	context.error = redact(trim(res.stderr))
	logger.logerror("git failed", context)
end

---@param res vim.SystemCompleted
---@param fallback string
---@return boolean, string|nil
local function command_result(res, fallback)
	if res.code == 0 then
		return true, nil
	end
	local err = trim(res.stderr)
	return false, err ~= "" and err or fallback
end

---@param line string
---@return string|nil label
---@return integer|nil percent
local function parse_progress(line)
	line = trim(line):gsub("^remote:%s*", "")
	local label, percent = line:match("^([^:]+):%s*(%d+)%%")
	return label and trim(label) or nil, percent and tonumber(percent) or nil
end

---@param args string[] Arguments after `git`.
---@param opts vim.SystemOpts|nil
---@param on_done fun(res: vim.SystemCompleted)
---@param on_progress (fun(label: string, percent: integer))|nil
---@return { cancel: fun() }
function M.run(args, opts, on_done, on_progress)
	local cancelled = false
	local system_opts = opts or {}
	local command = vim.list_extend({ "git" }, args)
	local context = { command = vim.tbl_map(redact, command), cwd = system_opts.cwd }
	logger.loginfo("git", context)
	local stderr = {}
	local pending = ""
	local last_progress = ""

	local function report_progress(line)
		local label, percent = parse_progress(line)
		if not label or percent == nil then
			return
		end
		local progress = label .. ":" .. percent
		if progress == last_progress then
			return
		end
		last_progress = progress
		vim.schedule(function()
			if not cancelled then
				on_progress(label, percent)
			end
		end)
	end

	if on_progress then
		system_opts = vim.tbl_extend("force", {}, system_opts)
		system_opts.stderr = function(_, data)
			if not data then
				return
			end
			table.insert(stderr, data)
			pending = pending .. data
			while true do
				local boundary = pending:find("[\r\n]")
				if not boundary then
					break
				end
				report_progress(pending:sub(1, boundary - 1))
				pending = pending:sub(boundary + 1)
			end
		end
	end

	local function finish(res)
		if on_progress then
			if pending ~= "" then
				report_progress(pending)
			end
			res.stderr = #stderr > 0 and table.concat(stderr) or res.stderr
		end
		if not cancelled then
			log_failure(res, context)
		end
		vim.schedule(function()
			if not cancelled then
				on_done(res)
			end
		end)
	end

	local ok, handle = pcall(vim.system, command, system_opts, finish)
	if not ok then
		finish({ code = -1, signal = 0, stdout = "", stderr = tostring(handle) })
		handle = nil
	end
	return {
		cancel = function()
			if cancelled then
				return
			end
			cancelled = true
			if handle then
				pcall(handle.kill, handle, 9)
			end
		end,
	}
end

---@return string
function M.default_cwd()
	local buf_name = vim.api.nvim_buf_get_name(0)
	if buf_name ~= "" then
		local dir = vim.fn.fnamemodify(buf_name, ":h")
		if vim.fn.isdirectory(dir) == 1 then
			return dir
		end
	end
	return vim.fn.getcwd()
end

---@param cwd string|nil
---@param on_done fun(root: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.repo_root(cwd, on_done)
	cwd = cwd or M.default_cwd()
	return M.run({ "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }, function(res)
		on_done(res.code == 0 and trim(res.stdout) or nil, res.code ~= 0 and "Not in a git repository" or nil)
	end)
end

---@param root string
---@param on_done fun(branch: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.current_branch(root, on_done)
	return M.run({ "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }, function(res)
		if res.code ~= 0 then
			on_done(nil, "Failed to detect current branch")
			return
		end
		local branch = trim(res.stdout)
		if branch == "HEAD" then
			on_done(nil, "Detached HEAD — checkout a branch first")
			return
		end
		on_done(branch, nil)
	end)
end

---@param root string
---@param rev string
---@param on_done fun(exists: boolean)
---@return { cancel: fun() }
function M.rev_exists(root, rev, on_done)
	return M.run(
		{ "-C", root, "rev-parse", "--verify", "--quiet", rev .. "^{commit}" },
		{ text = true, env = { GIT_NO_LAZY_FETCH = "1" } },
		function(res)
			on_done(res.code == 0)
		end
	)
end

---@param root string
---@param commits string[]
---@param on_done fun(exists: boolean[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.check_commits(root, commits, on_done)
	local queries = {}
	for index, commit in ipairs(commits) do
		queries[index] = commit .. "^{commit}"
	end
	return M.run({ "-C", root, "cat-file", "--batch-check=%(objecttype)" }, {
		text = true,
		stdin = table.concat(queries, "\n") .. "\n",
		env = { GIT_NO_LAZY_FETCH = "1" },
	}, function(res)
		local ok, err = command_result(res, "Failed to check commits")
		if not ok then
			on_done(nil, err)
			return
		end
		local exists = {}
		for index, result in ipairs(vim.split(res.stdout or "", "\n", { plain = true, trimempty = true })) do
			exists[index] = trim(result) == "commit"
		end
		on_done(exists, nil)
	end)
end

---@param root string
---@param base string
---@param head string
---@param on_done fun(base: string|nil, head: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.diff_revisions(root, base, head, on_done)
	base = trim(base)
	head = trim(head)
	if base == "" or head == "" then
		on_done(nil, nil, "Base and head branches are required")
		return nil
	end

	local remote_base = base:match("^origin/") and base or "origin/" .. base
	return M.check_commits(root, { remote_base, base, head }, function(exists, err)
		if not exists then
			on_done(nil, nil, err)
		elseif not exists[1] and not exists[2] then
			on_done(nil, nil, "Base branch not found: " .. base)
		elseif not exists[3] then
			on_done(nil, nil, "Head branch not found: " .. head)
		else
			on_done(exists[1] and remote_base or base, head, nil)
		end
	end)
end

---@param root string
---@param range string
---@param on_done fun(commits: { hash: string, subject: string }[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.commits_for_range(root, range, on_done)
	return M.run({ "-C", root, "log", "--reverse", "--format=%h %s", range }, { text = true }, function(res)
		local ok, err = command_result(res, "Failed to load commits")
		if not ok then
			on_done(nil, err)
			return
		end
		local commits = {}
		for line in (res.stdout or ""):gmatch("[^\r\n]+") do
			local hash, subject = line:match("^(%S+)%s+(.+)$")
			if hash and subject then
				table.insert(commits, { hash = hash, subject = trim(subject) })
			end
		end
		on_done(commits, nil)
	end)
end

---@param root string
---@param base string
---@param head string
---@param on_done fun(lines: string[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.diff_stat(root, base, head, on_done)
	return M.run(
		{ "-C", root, "diff", "--find-renames", "--stat", base .. "..." .. head, "--" },
		{ text = true },
		function(res)
			local ok, err = command_result(res, "Failed to load diff statistics")
			on_done(ok and vim.split(res.stdout or "", "\n", { plain = true, trimempty = true }) or nil, err)
		end
	)
end

---@param root string
---@param remote string|nil  -- defaults to "origin"
---@param on_done fun(url: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.remote_url(root, remote, on_done)
	remote = remote or "origin"
	return M.run({ "-C", root, "remote", "get-url", remote }, { text = true }, function(res)
		on_done(
			res.code == 0 and trim(res.stdout) or nil,
			res.code ~= 0 and string.format("Remote '%s' is not configured", remote) or nil
		)
	end)
end

---@param remote string
---@return AtlasTarget|nil target, string|nil err
function M.parse_remote_url(remote)
	local target, err = providers.resolve(remote)
	if target and target.entity == "repo" then
		return target
	end
	return nil, err or "Expected a supported Git repository remote"
end

---@param cwd string|nil
---@param on_done fun(target: AtlasTarget|nil, err: string|nil)
---@return { cancel: fun() }
function M.local_repository(cwd, on_done)
	return M.remote_url(cwd or M.default_cwd(), "origin", function(remote, err)
		if not remote then
			on_done(nil, err)
			return
		end
		on_done(M.parse_remote_url(remote))
	end)
end

---@param root string
---@param remote string|nil
---@param on_done fun(branch: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.default_branch(root, remote, on_done)
	remote = remote or "origin"
	local scope = requests.new()
	scope.run(function(done)
		return M.run({ "-C", root, "symbolic-ref", "refs/remotes/" .. remote .. "/HEAD" }, { text = true }, done)
	end, function(res)
		local branch = res.code == 0 and trim(res.stdout):match("refs/remotes/[^/]+/(.+)$") or nil
		if branch then
			on_done(branch, nil)
			return
		end
		scope.run(function(done)
			return M.run({ "-C", root, "ls-remote", "--symref", remote, "HEAD" }, { text = true }, done)
		end, function(result)
			local name = result.code == 0 and (result.stdout or ""):match("ref: refs/heads/([^%s]+)%s+HEAD") or nil
			on_done(name, not name and "Could not determine default branch" or nil)
		end)
	end)
	return scope
end

---@param root string
---@param remote string
---@param on_done fun(branches: string[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.list_remote_branches(root, remote, on_done)
	remote = remote or "origin"
	return M.run({ "-C", root, "branch", "-r", "--format=%(refname:short)" }, { text = true }, function(res)
		local ok, err = command_result(res, "Failed to list remote branches")
		if not ok then
			on_done(nil, err)
			return
		end
		local prefix = remote .. "/"
		local out = {}
		for line in (res.stdout or ""):gmatch("[^\r\n]+") do
			local name = trim(line)
			if name:sub(1, #prefix) == prefix then
				local short = name:sub(#prefix + 1)
				if short ~= "HEAD" then
					table.insert(out, short)
				end
			end
		end
		on_done(out, nil)
	end)
end

---@param root string
---@param branch string
---@param remote string|nil
---@param on_done fun(exists: boolean)
---@return { cancel: fun() }
function M.branch_exists_on_remote(root, branch, remote, on_done)
	remote = remote or "origin"
	return M.run({ "ls-remote", "--exit-code", "--heads", remote, branch }, { cwd = root, text = true }, function(res)
		on_done(res.code == 0)
	end)
end

---@param root string
---@param on_done fun(inside: boolean)
---@return { cancel: fun() }
function M.is_inside_work_tree(root, on_done)
	return M.run({ "-C", root, "rev-parse", "--is-inside-work-tree" }, { text = true }, function(res)
		on_done(res.code == 0)
	end)
end

---@param root string
---@param remote string
---@param refs string[]
---@param on_done fun(ok: boolean, err: string|nil)
---@param on_progress (fun(label: string, percent: integer))|nil
---@return { cancel: fun() }
function M.fetch_refs(root, remote, refs, on_done, on_progress)
	local args = { "fetch", "--no-tags", remote }
	if on_progress then
		table.insert(args, 2, "--progress")
	end
	vim.list_extend(args, refs)

	return M.run(args, { cwd = root, text = true }, function(res)
		on_done(command_result(res, string.format("git fetch failed with code %d", res.code)))
	end, on_progress)
end

---@param root string
---@param branch string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.checkout_branch(root, branch, on_done)
	return M.run({ "checkout", branch }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, "git checkout branch failed"))
	end)
end

---@param root string
---@param branch string
---@param start_point string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.checkout_new_branch(root, branch, start_point, on_done)
	return M.run({ "checkout", "-b", branch, start_point }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, "git checkout branch failed"))
	end)
end

---@param root string
---@param branch string
---@param remote string|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.push_branch(root, branch, remote, on_done)
	remote = remote or "origin"
	return M.run({ "push", "-u", remote, branch }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, string.format("git push failed with code %d", res.code)))
	end)
end

return M
