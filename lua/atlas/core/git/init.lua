local M = {}

local logger = require("atlas.core.logger")
local providers = require("atlas.providers")

local function trim(value)
	return vim.trim(value or "")
end

local function redact(value)
	return tostring(value or ""):gsub("(%a[%w+.-]*://)[^/@%s]+@", "%1***@")
end

---@param args string[]
---@param cwd string|nil
---@return string[] command
---@return table context
local function prepare_command(args, cwd)
	local command = vim.list_extend({ "git" }, args)
	local context = { command = vim.tbl_map(redact, command), cwd = cwd }
	logger.loginfo("git", context)
	return command, context
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

---@param args string[] Arguments after `git`.
---@param opts vim.SystemOpts
---@return vim.SystemCompleted
local function run_sync(args, opts)
	local command, context = prepare_command(args, opts.cwd)
	local res = vim.system(command, opts):wait()
	log_failure(res, context)
	return res
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
	local command, context = prepare_command(args, system_opts.cwd)
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

	local handle = vim.system(command, system_opts, function(res)
		if on_progress then
			if pending ~= "" then
				report_progress(pending)
			end
			res.stderr = table.concat(stderr)
		end
		if not cancelled then
			log_failure(res, context)
		end
		vim.schedule(function()
			if not cancelled then
				on_done(res)
			end
		end)
	end)
	return {
		cancel = function()
			if cancelled then
				return
			end
			cancelled = true
			pcall(handle.kill, handle, 9)
		end,
	}
end

---@return string
local function default_cwd()
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
---@return string|nil root, string|nil err
function M.repo_root(cwd)
	cwd = cwd or default_cwd()
	local res = run_sync({ "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true })
	if res.code ~= 0 then
		return nil, "Not in a git repository"
	end
	return trim(res.stdout), nil
end

---@param root string
---@return string|nil branch, string|nil err
function M.current_branch(root)
	local res = run_sync({ "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true })
	if res.code ~= 0 then
		return nil, "Failed to detect current branch"
	end
	local branch = trim(res.stdout)
	if branch == "HEAD" then
		return nil, "Detached HEAD — checkout a branch first"
	end
	return branch, nil
end

---@param root string
---@param rev string
---@return boolean
function M.rev_exists(root, rev)
	local res = run_sync(
		{ "-C", root, "rev-parse", "--verify", "--quiet", rev .. "^{commit}" },
		{ text = true, env = { GIT_NO_LAZY_FETCH = "1" } }
	)
	return res.code == 0
end

---@param root string
---@param commits string[]
---@return boolean[]
function M.check_commits(root, commits)
	local queries = {}
	for index, commit in ipairs(commits) do
		queries[index] = commit .. "^{commit}"
	end
	local res = run_sync({ "-C", root, "cat-file", "--batch-check=%(objecttype)" }, {
		text = true,
		stdin = table.concat(queries, "\n") .. "\n",
		env = { GIT_NO_LAZY_FETCH = "1" },
	})
	local exists = {}
	for index, result in ipairs(vim.split(res.stdout or "", "\n", { plain = true, trimempty = true })) do
		exists[index] = trim(result) == "commit"
	end
	return exists
end

---@param root string
---@param base string
---@param head string
---@return string|nil base_revision
---@return string|nil head_revision
---@return string|nil err
function M.diff_revisions(root, base, head)
	base = trim(base)
	head = trim(head)
	if base == "" or head == "" then
		return nil, nil, "Base and head branches are required"
	end

	local base_revision = base
	local remote_base = base:match("^origin/") and base or "origin/" .. base
	if M.rev_exists(root, remote_base) then
		base_revision = remote_base
	elseif not M.rev_exists(root, base) then
		return nil, nil, "Base branch not found: " .. base
	end
	if not M.rev_exists(root, head) then
		return nil, nil, "Head branch not found: " .. head
	end
	return base_revision, head, nil
end

---@param root string
---@param base string
---@param head string
---@return string|nil range
---@return string|nil err
function M.commit_range(root, base, head)
	local base_revision, head_revision, err = M.diff_revisions(root, base, head)
	if not base_revision or not head_revision then
		return nil, err
	end
	return base_revision .. ".." .. head_revision
end

---@param root string
---@param range string
---@return { hash: string, subject: string }[]
function M.commits_for_range(root, range)
	local res = run_sync({ "-C", root, "log", "--reverse", "--format=%h %s", range }, { text = true })
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
---@param base string
---@param head string
---@return string[]|nil lines
---@return string|nil err
function M.diff_stat(root, base, head)
	local base_revision, head_revision, revision_err = M.diff_revisions(root, base, head)
	if not base_revision or not head_revision then
		return nil, revision_err
	end
	local range = base_revision .. "..." .. head_revision
	local res = run_sync({ "-C", root, "diff", "--find-renames", "--stat", range, "--" }, { text = true })
	if res.code ~= 0 then
		local err = trim(res.stderr)
		return nil, err ~= "" and err or "Failed to load diff statistics"
	end

	local lines = {}
	for line in tostring(res.stdout or ""):gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	return lines, nil
end

---@param root string
---@param remote string|nil  -- defaults to "origin"
---@return string|nil url, string|nil err
function M.remote_url(root, remote)
	remote = remote or "origin"
	local res = run_sync({ "-C", root, "remote", "get-url", remote }, { text = true })
	if res.code ~= 0 then
		return nil, string.format("Remote '%s' is not configured", remote)
	end
	return trim(res.stdout), nil
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
---@return AtlasTarget|nil
function M.local_repository(cwd)
	local remote_url = M.remote_url(cwd or default_cwd(), "origin")
	return remote_url and M.parse_remote_url(remote_url) or nil
end

---@param root string
---@param remote string|nil
---@return string|nil branch, string|nil err
function M.default_branch(root, remote)
	remote = remote or "origin"

	local res = run_sync({ "-C", root, "symbolic-ref", "refs/remotes/" .. remote .. "/HEAD" }, { text = true })
	if res.code == 0 then
		local ref = trim(res.stdout)
		local branch = ref:match("refs/remotes/[^/]+/(.+)$")
		if branch then
			return branch, nil
		end
	end

	res = run_sync({ "-C", root, "ls-remote", "--symref", remote, "HEAD" }, { text = true })
	if res.code == 0 then
		local ref = res.stdout:match("ref: refs/heads/([^%s]+)%s+HEAD")
		if ref then
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
	local res = run_sync({ "-C", root, "branch", "-r", "--format=%(refname:short)" }, { text = true })
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
---@param on_done fun(exists: boolean)
---@return { cancel: fun() }
function M.branch_exists_on_remote(root, branch, remote, on_done)
	remote = remote or "origin"
	return M.run({ "ls-remote", "--exit-code", "--heads", remote, branch }, { cwd = root, text = true }, function(res)
		on_done(res.code == 0)
	end)
end

---@param root string
---@return boolean
function M.is_inside_work_tree(root)
	local res = run_sync({ "-C", root, "rev-parse", "--is-inside-work-tree" }, { text = true })
	return res.code == 0
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
function M.checkout_branch(root, branch, on_done)
	M.run({ "checkout", branch }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, "git checkout branch failed"))
	end)
end

---@param root string
---@param branch string
---@param start_point string
---@param on_done fun(ok: boolean, err: string|nil)
function M.checkout_new_branch(root, branch, start_point, on_done)
	M.run({ "checkout", "-b", branch, start_point }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, "git checkout branch failed"))
	end)
end

---@param root string
---@param branch string
---@param remote string|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.push_branch(root, branch, remote, on_done)
	remote = remote or "origin"
	M.run({ "push", "-u", remote, branch }, { cwd = root, text = true }, function(res)
		on_done(command_result(res, string.format("git push failed with code %d", res.code)))
	end)
end

return M
