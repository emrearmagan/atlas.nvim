local diff_git = require("atlas.pulls.diff.git")
local diff_worktree = require("atlas.pulls.diff.worktree")
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
---@field range AtlasDiffRange
---@field files AtlasDiffFile[]
---@field worktree_root string|nil
---@field commits PullsCommit[]
---@field review PullsReviewData|nil
---@field reviewed_files table<string, boolean>|nil
---@field current_user AtlasUser|nil
---@field notes { target: AtlasStorageTarget, items: AtlasNote[], positions: table<string, AtlasNotePosition> }|nil
---@field requests { load?: AtlasRequestScope, reload?: AtlasRequestScope, reviewed: table<string, AtlasRequestScope> }
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
		requests = { reviewed = {} },
		closed = false,
	}, Session)
	local request = request_scope.new()
	session.requests.load = request
	local pr = source.kind == "pr" and source.pr or nil
	local starts = {}

	if pr then
		local provider = providers.load(pr.provider, "pulls")
		---@cast provider PullsProvider
		local capabilities = provider.capabilities
		session.reviewed_files = capabilities.reviews and {} or nil
		starts = review_starts(pr, root, head)
		if capabilities.core.fetch_commits then
			starts.commits = function(done)
				return capabilities.core.fetch_commits(pr, { force_refresh = true }, done)
			end
		end
		if capabilities.users then
			starts.current_user = capabilities.users.fetch_user
		end
	end

	starts.diff = function(done)
		request.run(function(loaded)
			return diff_git.load(root, base, head, loaded)
		end, function(diff, err)
			if not diff then
				done(nil, err)
				return
			end

			session.range = diff.range
			session.files = diff.files
			if not opts.lsp or #diff.files == 0 then
				done(true)
				return
			end

			opts.on_progress("Preparing worktree...")
			request.run(function(prepared)
				return diff_worktree.prepare(diff.range, pr, opts.lsp, prepared)
			end, function(path)
				session.worktree_root = path
				done(true)
			end)
		end)
		return nil
	end

	opts.on_progress(pr and "Loading changed files and review data..." or "Loading changed files...")
	request.all(starts, function(values, errors)
		session.requests.load = nil
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
	for _, request in pairs({ self.requests.load, self.requests.reload }) do
		request.cancel()
	end
	for _, request in pairs(self.requests.reviewed) do
		request.cancel()
	end

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

	local request = request_scope.new()
	for _, path in ipairs(paths) do
		self.requests.reviewed[path] = request
	end
	request.run(function(done)
		return reviews.set_files_reviewed(pr, paths, reviewed, done)
	end, function(ok, err)
		for _, path in ipairs(paths) do
			self.requests.reviewed[path] = nil
		end
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
	if self.requests.reload then
		self.requests.reload.cancel()
	end
	local request = request_scope.new()
	self.requests.reload = request

	local source = self.source
	local range = self.range
	local starts = source.kind == "pr" and review_starts(source.pr, range.root, range.head_revision) or {}
	request.all(starts, function(values, errors)
		self.requests.reload = nil
		apply_review(self, values)
		if next(errors) then
			notify.warn("Unable to load some review data")
		end
		on_done(next(errors) == nil)
	end)
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
