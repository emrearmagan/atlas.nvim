local config = require("atlas.config")
local console = require("atlas.ui.console")
local diff = require("atlas.pulls.diff")
local diff_worktree = require("atlas.pulls.diff.worktree")
local git = require("atlas.core.git")
local git_diff = require("atlas.core.git.diff")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local M = {}

---@class AtlasDiffEditFile: AtlasDiffFile
---@field edited boolean|nil Compared with HEAD, so it only shows your edits.
---@field changed boolean|nil A pull request file that also has edits.

---@class AtlasDiffEdit
---@field pr PullRequest
---@field review AtlasDiffViewer
---@field repo_root string
---@field message string|nil
---@field pushing boolean|nil

-- Edit sessions by the path of their worktree.
---@type table<string, AtlasDiffEdit>
local edits = {}

---@param root string
---@return string
local function edit_key(root)
	return vim.uv.fs_realpath(root) or root
end

---@param viewer AtlasDiffViewer
---@return AtlasDiffEdit
local function edit_of(viewer)
	return assert(edits[edit_key(viewer.session.range.root)])
end

---@param action AtlasKeymapActionId
---@return string
local function key(action)
	local keymap = keymaps.resolve(action)
	return keymap and table.concat(keymap.key, "/") or ""
end

---@param root string
---@return integer[]
local function unsaved_buffers(root)
	return vim.tbl_filter(function(buf)
		return vim.api.nvim_buf_is_loaded(buf)
			and vim.bo[buf].modified
			and diff_worktree.relative_path(root, vim.api.nvim_buf_get_name(buf)) ~= nil
	end, vim.api.nvim_list_bufs())
end

---@param root string
local function save(root)
	for _, buf in ipairs(unsaved_buffers(root)) do
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent write")
		end)
	end
end

---@param root string
---@param on_done fun(changes: string[]) `git status --porcelain` lines
local function load_changes(root, on_done)
	git.run({ "status", "--porcelain" }, { cwd = root, text = true }, function(result)
		on_done(vim.split(result.stdout or "", "\n", { trimempty = true }))
	end)
end

-- The pull request's files against its base, plus your edits against HEAD in their own section.
---@param root string
---@param base string
---@param on_done fun(result: { range: AtlasDiffRange, files: AtlasDiffFile[], hunks: { base: table<string, DiffHunk[]>, head: table<string, DiffHunk[]> } }|nil, err: string|nil)
---@return { cancel: fun() }
function M.load(root, base, on_done)
	local requests = request_scope.new()
	requests.all({
		files = function(done)
			return git_diff.load(root, base, nil, done)
		end,
		edited = function(done)
			return git_diff.load(root, "HEAD", nil, done)
		end,
		hunks = function(done)
			return git_diff.hunks(root, "HEAD", nil, done)
		end,
	}, function(values, errors)
		local _, err = next(errors)
		if err then
			on_done(nil, err)
			return
		end

		local files = values.files.files
		local edited = {}
		for _, file in ipairs(values.edited.files) do
			---@cast file AtlasDiffEditFile
			file.edited = true
			edited[file.path] = true
		end
		for _, file in ipairs(files) do
			---@cast file AtlasDiffEditFile
			file.changed = edited[file.path]
		end
		vim.list_extend(files, values.edited.files)
		on_done({ range = values.files.range, files = files, hunks = { base = {}, head = values.hunks } }, nil)
	end)
	return { cancel = requests.cancel }
end

---@param review AtlasDiffViewer
---@param suggestions AtlasDiffSuggestion[]|nil Applied to the worktree before it opens.
function M.start(review, suggestions)
	local session = review.session
	local source = session.source
	if source.kind ~= "pr" then
		return
	end
	if session:shown_commits() then
		notify.info("Show all commits to edit the pull request")
		return
	end

	-- An edit only ends on discard or push, so reopen an existing one with its changes.
	for root, edit in pairs(edits) do
		if edit.pr.repo_full_name == source.pr.repo_full_name and edit.pr.id == source.pr.id then
			if suggestions then
				notify.warn("Commit or discard your edits first")
			end
			edit.review = review
			diff.open_worktree({ root = root, base = session.range.base_revision, edit = session })
			return
		end
	end

	notify.info("Preparing a worktree to edit in...")
	session.requests.run(function(done)
		return diff_worktree.prepare(session.range, source.pr, config.options.pulls.diff.lsp, done)
	end, function(root)
		if not root then
			return
		end

		local edit = { pr = source.pr, review = review, repo_root = session.range.root }
		if suggestions then
			require("atlas.pulls.diff.suggestions").apply(root, suggestions)
			edit.message = #suggestions == 1 and "Update " .. vim.fs.basename(suggestions[1].path)
				or "Apply suggestions from code review"
		end
		edits[edit_key(root)] = edit
		diff.open_worktree({ root = root, base = session.range.base_revision, edit = session })
	end)
end

-- The provider updates the pull request a moment after a push, so a reload right away can miss the commit.
---@param pr PullRequest
---@param head string
---@param on_done fun()
local function wait_for_head(pr, head, on_done)
	local provider = providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider
	local ref = { provider = pr.provider, repo_full_name = pr.repo_full_name, id = pr.id }
	local output = console.start("Waiting for the pull request to show " .. head:sub(1, 7))
	console.open(false, 300)

	local function check(attempt)
		provider.capabilities.core.fetch_by_refs({ ref }, { force_refresh = true }, function(pulls)
			local current = pulls and pulls[1]
			local found = current ~= nil and current.source.commit_hash == head
			output:write(string.format("Attempt %d/5: %s\r\n", attempt, found and "found" or "not yet"))
			if found or attempt == 5 then
				output:close()
				on_done()
				return
			end

			vim.defer_fn(function()
				check(attempt + 1)
			end, 1000)
		end)
	end
	check(1)
end

---@param viewer AtlasDiffViewer
---@param reload boolean
local function stop(viewer, reload)
	local edit = edit_of(viewer)
	local root = viewer.session.range.root
	edits[edit_key(root)] = nil
	viewer:close("user_close")

	-- discard() keeps buffers with unsaved changes, but ending an edit is on purpose, so remove those too.
	for _, buf in ipairs(unsaved_buffers(root)) do
		vim.bo[buf].modified = false
	end
	diff_worktree.discard(edit.repo_root, root)
	if not edit.review.session.closed then
		vim.api.nvim_set_current_tabpage(edit.review.renderer.tabpage)
		if reload then
			edit.review:reload()
		end
	end
end

---@param root string
---@param pr PullRequest
---@param message string
---@param on_done fun(head: string|nil) The pushed commit, or nil when a step failed.
local function push(root, pr, message, on_done)
	local url = config.options.pulls.git_transport == "ssh" and pr.source.ssh_url or pr.source.https_url
	local steps = {
		{ "add", "-A" },
		{ "commit", "-m", message },
		{ "push", (url and url ~= "") and url or "origin", "HEAD:refs/heads/" .. pr.source.branch },
	}

	local function run(index)
		local args = steps[index]
		if not args then
			git.run({ "rev-parse", "HEAD" }, { cwd = root, text = true }, function(result)
				on_done(vim.trim(result.stdout))
			end)
			return
		end
		git.run(args, { cwd = root, text = true, console = true }, function(result)
			if result.code ~= 0 then
				notify.error(string.format("git %s failed\n\n%s", args[1], vim.trim(result.stderr)))
				-- Undo the commit so a retry can commit again.
				if args[1] == "push" then
					git.run({ "reset", "--soft", "HEAD~1" }, { cwd = root }, function()
						on_done(nil)
					end)
					return
				end
				on_done(nil)
				return
			end
			run(index + 1)
		end)
	end
	run(1)
end

---@param viewer AtlasDiffViewer
---@param changes string[] `git status --porcelain` lines
local function open_commit(viewer, changes)
	local edit = edit_of(viewer)
	local root = viewer.session.range.root
	local branch = edit.pr.source.branch

	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "_COMMIT_EDITMSG")
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "gitcommit"
	vim.cmd("botright " .. math.max(12, math.floor(vim.o.lines * 0.35)) .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	for name, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		diff = false,
		scrollbind = false,
		cursorbind = false,
		foldenable = false,
		wrap = true,
	}) do
		vim.wo[win][name] = value
	end

	---@param list string[]
	local function footer(list)
		local lines = {
			string.format("# Commit and push to %s (%s #%s)", branch, edit.pr.repo_full_name, edit.pr.id),
			"#",
			"# Changes:",
		}
		for _, change in ipairs(list) do
			lines[#lines + 1] = "#   " .. change
		end
		return vim.list_extend(lines, {
			"#",
			string.format("# %s commit and push, %s keep editing", key("ui.submit"), key("ui.close")),
			"# Lines starting with '#' will be ignored.",
		})
	end
	local initial = vim.split(edit.message or "", "\n", { plain = true })
	initial[#initial + 1] = ""
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(initial, footer(changes)))
	vim.api.nvim_win_set_cursor(win, { 1, 0 })

	-- Files can change while this is open, so list what would be committed now.
	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = buf,
		callback = function()
			save(root)
			load_changes(root, function(list)
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local first = #lines
				for row, line in ipairs(lines) do
					if line:sub(1, 1) == "#" then
						first = row - 1
						break
					end
				end
				vim.api.nvim_buf_set_lines(buf, first, -1, false, footer(list))
			end)
		end,
	})

	local function read_message()
		return vim.trim(table.concat(
			vim.tbl_filter(function(line)
				return line:sub(1, 1) ~= "#"
			end, vim.api.nvim_buf_get_lines(buf, 0, -1, false)),
			"\n"
		))
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			edit.message = read_message()
		end,
	})

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function submit()
		local message = read_message()
		if message == "" then
			notify.warn("Commit message cannot be empty")
			return
		end
		vim.cmd("stopinsert")
		save(root)
		close()
		edit.pushing = true

		console.clear()
		notify.info("Pushing to " .. branch .. "...")
		push(root, edit.pr, message, function(head)
			if not head then
				edit.pushing = false
				return
			end

			notify.info("Pushed to " .. branch)
			wait_for_head(edit.pr, head, function()
				edit.pushing = false
				stop(viewer, true)
			end)
		end)
	end

	for action, mapping in pairs({
		["ui.submit"] = { modes = { "n", "i" }, callback = submit },
		["ui.close"] = { modes = "n", callback = close },
	}) do
		local keymap = keymaps.resolve(action)
		for _, lhs in ipairs(keymap and keymap.key or {}) do
			vim.keymap.set(mapping.modes, lhs, mapping.callback, { buffer = buf, nowait = true, silent = true })
		end
	end
end

---@param viewer AtlasDiffViewer
function M.commit(viewer)
	if edit_of(viewer).pushing then
		notify.info("Still pushing...")
		return
	end

	local root = viewer.session.range.root
	save(root)
	load_changes(root, function(changes)
		if #changes == 0 then
			notify.info("No changes to commit")
			return
		end
		open_commit(viewer, changes)
	end)
end

---@param viewer AtlasDiffViewer
function M.close(viewer)
	if edit_of(viewer).pushing then
		notify.info("Still pushing...")
		return
	end

	local root = viewer.session.range.root
	local unsaved = #unsaved_buffers(root) > 0
	load_changes(root, function(changes)
		if
			(unsaved or #changes > 0)
			and vim.fn.confirm("Discard your edits?", "&Discard\n&Cancel", 2, "Warning") ~= 1
		then
			return
		end
		stop(viewer, false)
	end)
end

return M
