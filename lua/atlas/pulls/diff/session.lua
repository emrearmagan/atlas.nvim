local diff_git = require("atlas.pulls.diff.git")
local diff_worktree = require("atlas.pulls.diff.worktree")
local git = require("atlas.core.git")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

---@class AtlasDiffPullRequestSource
---@field kind "pr"
---@field pr PullRequest

---@class AtlasDiffRefsSource
---@field kind "refs"
---@field base string
---@field head string

---@alias AtlasDiffSource AtlasDiffPullRequestSource|AtlasDiffRefsSource

---@class AtlasDiffSession
---@field source AtlasDiffSource
--- This is the range that was initially opened like a pr or branch. It mainly just used to determine if the user is viewing a single commit or the full range and come back here
---@field full_range AtlasDiffRange
---@field range AtlasDiffRange
---@field files AtlasDiffFile[]
---@field worktree_root string|nil
---@field commits AtlasGitCommit[]
---@field review PullsReviewData|nil
---@field reviewed_files table<string, boolean>|nil
---@field current_user AtlasUser|nil
---@field notes { target: AtlasStorageTarget, items: AtlasNote[], positions: table<string, AtlasNotePosition> }|nil
---@field requests AtlasRequestScope
---@field closed boolean
local Session = {}
Session.__index = Session

---@param pr PullRequest
---@param root string
---@param head string
---@return table<string, fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil>
local function review_starts(pr, root, head)
	local starts = {
		notes = function(done)
			local data, err = notes.for_pull_request(pr)
			if not data then
				done(nil, err)
				return nil
			end
			return notes.locate(root, head, data.items, function(positions)
				done({ target = data.target, items = data.items, positions = positions })
			end)
		end,
	}

	local provider = providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider
	local reviews = provider.capabilities.reviews
	if reviews then
		starts.review = function(done)
			return reviews.fetch(pr, { force_refresh = true }, done)
		end
		if reviews.fetch_review_context then
			starts.review_context = function(done)
				return reviews.fetch_review_context(pr, { force_refresh = true }, done)
			end
		end
	end
	return starts
end

---@param session AtlasDiffSession
---@param values table<string, any>
local function apply_review(session, values)
	if values.notes then
		session.notes = values.notes
	end
	if values.review and session.review then
		for key, value in pairs(values.review) do
			session.review[key] = value
		end
	elseif values.review then
		session.review = values.review
	end
	local context = values.review_context
	if session.reviewed_files and context and context.reviewed_files then
		session.reviewed_files = vim.deepcopy(context.reviewed_files)
	end
end

---@param source AtlasDiffSource
---@param root string
---@param base string
---@param head string
---@param opts { lsp?: AtlasPullsDiffLspConfig, on_progress: fun(message: string) }
---@param on_done fun(session: AtlasDiffSession|nil, err: string|nil)
---@return { cancel: fun() }
function Session.new(source, root, base, head, opts, on_done)
	local session = setmetatable({
		source = source,
		files = {},
		commits = {},
		requests = request_scope.new(),
		closed = false,
	}, Session)
	local pr = source.kind == "pr" and source.pr or nil
	local starts = {}

	if pr then
		local provider = providers.load(pr.provider, "pulls")
		---@cast provider PullsProvider
		local capabilities = provider.capabilities
		session.reviewed_files = capabilities.reviews and {} or nil
		starts = review_starts(pr, root, head)
		if capabilities.users then
			starts.current_user = capabilities.users.fetch_user
		end
	end

	starts.commits = function(done)
		return git.branch_commits(root, base .. ".." .. head, done)
	end
	starts.diff = function(done)
		session.requests.run(function(loaded)
			return diff_git.load(root, base, head, loaded)
		end, function(diff, err)
			if not diff then
				done(nil, err)
				return
			end

			session.full_range = diff.range
			session.range = diff.range
			session.files = diff.files
			if not opts.lsp or #diff.files == 0 then
				done(true)
				return
			end

			opts.on_progress("Preparing worktree...")
			session.requests.run(function(prepared)
				return diff_worktree.prepare(diff.range, pr, opts.lsp, prepared)
			end, function(path)
				session.worktree_root = path
				done(true)
			end)
		end)
		return nil
	end

	opts.on_progress(pr and "Loading changed files and review data..." or "Loading changed files...")
	session.requests.all(starts, function(values, errors)
		if not values.diff then
			session:close()
			on_done(nil, errors.diff)
			return
		end

		if next(errors) then
			notify.warn("Unable to load some review data")
		end
		session.commits = values.commits or {}
		session.current_user = values.current_user
		apply_review(session, values)
		on_done(session, nil)
	end)

	return {
		cancel = function()
			session:close()
		end,
	}
end

function Session:close()
	if self.closed then
		return
	end

	self.closed = true
	self.requests.cancel()

	if self.worktree_root then
		diff_worktree.discard(self.range.root, self.worktree_root)
	end
end

---@param files AtlasDiffFile[]
---@param reviewed boolean
function Session:set_reviewed(files, reviewed)
	local reviewed_files = self.reviewed_files
	---@cast reviewed_files -nil
	local paths = {}
	for _, file in ipairs(files) do
		reviewed_files[file.path] = reviewed or nil
		paths[#paths + 1] = file.path
	end

	local pr = self.source.pr
	---@cast pr PullRequest
	local provider = providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider
	local reviews = provider.capabilities.reviews
	if not reviews or not reviews.set_files_reviewed then
		return
	end

	reviews.set_files_reviewed(pr, paths, reviewed, function(ok, err)
		if ok then
			return
		end

		logger.logerror("diff.set_files_reviewed failed", {
			provider = pr.provider,
			repo = pr.repo_full_name,
			pr_id = pr.id,
			paths = paths,
			error = err,
		})
		local message = "Unable to update reviewed files" .. (err and "\n\n" .. err or "")
		notify.error(message, { vim_notify = true })
	end)
end

---@param on_done fun(ok: boolean)
function Session:reload(on_done)
	local source = self.source
	local range = self.full_range
	local starts = source.kind == "pr" and review_starts(source.pr, range.root, range.head_revision) or {}
	self.requests.all(starts, function(values, errors)
		apply_review(self, values)
		if next(errors) then
			notify.warn("Unable to load some review data")
		end
		on_done(next(errors) == nil)
	end)
end

---@param from AtlasGitCommit|nil
---@param to AtlasGitCommit|nil
---@param on_done fun()
function Session:show_commits(from, to, on_done)
	local full_range = self.full_range
	local base, head = full_range.base_revision, full_range.head_revision
	if from and to then
		base, head = from.hash .. "^", to.hash
	end

	self.requests.run(function(done)
		return diff_git.load(full_range.root, base, head, done)
	end, function(diff, err)
		if not diff then
			notify.error("Unable to load changed files" .. (err and "\n\n" .. err or ""), { vim_notify = true })
			return
		end
		if #diff.files == 0 then
			notify.info("No changed files")
			return
		end

		self.range = from and to and diff.range or full_range
		self.files = diff.files
		on_done()
	end)
end

---@return AtlasGitCommit[]|nil
function Session:shown_commits()
	if self.range == self.full_range then
		return nil
	end

	local shown = {}
	for _, commit in ipairs(self.commits) do
		if commit.hash == self.range.head_revision or #shown > 0 then
			shown[#shown + 1] = commit
			if commit.parent == self.range.base_revision then
				break
			end
		end
	end

	return shown
end

---@return string|nil
function Session:head_worktree()
	-- The worktree is checked out at the head of the full range, so on a single commit it would show the wrong
	-- right side. That why commit views have no LSP (for now).
	-- I mean we could switch the worktree to the commit, but then
	-- open buffers need reloading, the LSP reindexes on every step and other Neovims on the same PR get their files
	-- swapped under them. Not worth it yet..
	return not self:shown_commits() and self.worktree_root or nil
end

---@param note AtlasNote
function Session:put_note(note)
	local data = self.notes
	---@cast data -nil
	for index, existing in ipairs(data.items) do
		if existing.id == note.id then
			data.items[index] = note
			return
		end
	end

	data.items[#data.items + 1] = note
	data.positions[note.id] = { start_line = note.start_line, end_line = note.end_line, outdated = false }
end

---@param note AtlasNote
function Session:remove_note(note)
	local data = self.notes
	---@cast data -nil
	for index, existing in ipairs(data.items) do
		if existing.id == note.id then
			table.remove(data.items, index)
			break
		end
	end
	data.positions[note.id] = nil
end

return Session
