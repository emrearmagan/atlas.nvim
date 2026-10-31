local M = {}

local description = require("atlas.pulls.create.description")
local form = require("atlas.ui.form")
local git = require("atlas.core.git")
local keymaps = require("atlas.core.keymaps")
local meta = require("atlas.pulls.editor.meta")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local presentation = require("atlas.pulls.ui.presentation")
local providers = require("atlas.providers")
local requests = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

---@class PullsCreatePRState
---@field repo_root string
---@field repo_slug string
---@field repository AtlasTarget
---@field head string
---@field base string
---@field draft boolean
---@field branches string[]
---@field reviewer_candidates PullsReviewerCandidate[]
---@field reviewers PullsReviewerCandidate[]
---@field commits_buf integer
---@field requests AtlasRequestScope
---@field loading boolean
---@field submitting boolean
---@field write PullsWriteCapability

---@param state PullsCreatePRState
---@param content PullsCreateDescription
local function render_commits(state, content)
	if not utils.buffer.valid(state.commits_buf) then
		return
	end

	local lines = vim.tbl_map(function(commit)
		return string.format("%s  %s", commit.hash, commit.subject)
	end, content.commits)
	if #lines == 0 then
		lines[1] = "No commits"
	end
	if #content.diffstat > 0 then
		lines[#lines + 1] = ""
		vim.list_extend(lines, content.diffstat)
	end

	vim.bo[state.commits_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.commits_buf, 0, -1, false, lines)
	vim.bo[state.commits_buf].modifiable = false
end

---@param state PullsCreatePRState
---@param editor AtlasForm
---@param content PullsCreateDescription
local function open_commits(state, editor, content)
	local buf = state.commits_buf
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].undolevels = -1
	vim.api.nvim_buf_set_name(buf, string.format("atlas://form/%d/commits", editor.editor_buf))
	render_commits(state, content)

	local win = vim.api.nvim_open_win(buf, false, {
		split = "below",
		win = editor.editor_win,
		height = math.max(8, math.min(15, math.floor(vim.o.lines * 0.3))),
	})
	local options = vim.wo[win]
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.foldcolumn = "0"
	options.statuscolumn = ""
	options.cursorline = false
	options.foldenable = false
	options.wrap = false
	options.winfixheight = true
	options.winbar = "Commits"

	editor.statusline:attach(win)
	require("atlas.ui.form.keymaps").setup(editor, editor.opts.close or form.close, { buf })
end

---@param state PullsCreatePRState
---@param editor AtlasForm
local function refresh_description(state, editor)
	state.requests.cancel()
	state.loading = true
	editor.statusline:notify("loading", "Updating description...")
	form.render_meta(editor)

	state.requests = description.build(
		state.repo_root,
		state.repo_slug,
		state.base,
		state.head,
		state.repository,
		function(content, err)
			state.loading = false
			form.render_meta(editor)
			if not content then
				---@cast err string
				editor.statusline:notify("error", err)
				return
			end

			form.set_content(editor, { body = content.body })
			render_commits(state, content)
			editor.statusline:clear_notice()
		end
	)
end

---@param state PullsCreatePRState
---@param editor AtlasForm
local function select_base(state, editor)
	if state.submitting then
		return
	end

	local initial_index
	for i, branch in ipairs(state.branches) do
		if branch == state.base then
			initial_index = i
			break
		end
	end

	picker.select({
		title = "Target branch",
		items = state.branches,
		initial_index = initial_index,
		on_select = function(branch)
			if branch and branch ~= state.base and not editor.closed and not state.submitting then
				state.base = branch
				refresh_description(state, editor)
			end
		end,
	})
end

---@param state PullsCreatePRState
---@param editor AtlasForm
local function select_reviewers(state, editor)
	if state.submitting then
		return
	end

	picker.multi_select({
		title = "Reviewers",
		items = state.reviewer_candidates,
		selected = state.reviewers,
		key = function(reviewer)
			return reviewer.provider_id
		end,
		format_item = function(reviewer)
			return reviewer.label
		end,
		on_done = function(selected)
			if not editor.closed and not state.submitting then
				state.reviewers = selected
				form.render_meta(editor)
			end
		end,
	})
end

---@param state PullsCreatePRState
---@param editor AtlasForm
local function preview_diff(state, editor)
	if state.loading or state.submitting then
		return
	end

	state.requests.run(function(done)
		return git.diff_revisions(state.repo_root, state.base, state.head, done)
	end, function(base, head, err)
		if err then
			editor.statusline:notify("error", err)
			return
		end

		editor.statusline:clear_notice()
		require("atlas.pulls.diff").open_range({ root = state.repo_root, base = base, head = head })
	end)
end

---@param state PullsCreatePRState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end
	if state.loading then
		editor.statusline:notify("warn", "Wait for the description to finish updating")
		return
	end

	local content = form.get_content(editor)
	local title = vim.trim(content.title)
	if title == "" then
		editor.statusline:notify("warn", "Title is required")
		return
	end
	if state.head == state.base then
		editor.statusline:notify("warn", "Head and base branches must differ")
		return
	end

	local opts = {
		repo_slug = state.repo_slug,
		title = title,
		body = content.body,
		head = state.head,
		base = state.base,
		draft = state.draft,
		reviewers = state.reviewers,
	}
	state.submitting = true
	state.requests.cancel()
	state.requests = requests.new()
	vim.bo[editor.editor_buf].modifiable = false

	---@param result PullsCreatePRResult|nil
	---@param err string|nil
	local function done(result, err)
		state.submitting = false
		if not result then
			---@cast err string
			if editor.closed then
				notify.error(err)
			else
				vim.bo[editor.editor_buf].modifiable = true
				editor.statusline:notify("error", err)
			end
			return
		end

		local was_closed = editor.closed
		form.close(editor)
		local message = result.message or "PR created"
		if result.url then
			message = message .. ": " .. result.url
			pcall(vim.fn.setreg, "+", result.url)
		end
		notify.info(message, { vim_notify = true })
		if result.url and not was_closed then
			require("atlas.commands.open").open(result.url)
		end
	end

	editor.statusline:notify("loading", "Pushing " .. state.head .. " to origin...")
	state.requests.run(function(callback)
		return git.push_branch(state.repo_root, state.head, "origin", callback)
	end, function(ok, err)
		if not ok then
			done(nil, err)
			return
		end

		editor.statusline:notify("loading", "Creating pull request...")
		state.write.create(opts, done)
	end)
end

---@param state PullsCreatePRState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local reviewers = vim.tbl_map(function(reviewer)
		return reviewer.label
	end, state.reviewers)

	local rows = {
		{ { key = "Repo:", value = state.repo_slug, hl = presentation.repo_hl(state.repo_slug) } },
		{
			{ key = "Head:", value = state.head },
			{ key = "Base:", value = state.base, loading = state.loading },
		},
		{
			{
				key = "State:",
				value = state.draft and "DRAFT" or "READY",
				hl = presentation.pr_state_hl(state.draft and "draft" or "open"),
			},
		},
	}
	if state.write.fetch_reviewer_candidates then
		rows[#rows + 1] = { meta.people("Reviewers:", reviewers, "None") }
	end
	return rows
end

---@param state PullsCreatePRState
---@param content PullsCreateDescription
---@return AtlasForm
local function open_editor(state, content)
	local form_keymaps = {
		{
			key = keymaps.resolve("editor.base"),
			desc = "base",
			action = function(editor)
				select_base(state, editor)
			end,
		},
		{
			key = keymaps.resolve("editor.draft"),
			desc = "draft",
			action = function(editor)
				if state.submitting then
					return
				end
				state.draft = not state.draft
				form.render_meta(editor)
			end,
		},
	}
	if state.write.fetch_reviewer_candidates then
		table.insert(form_keymaps, 2, {
			key = keymaps.resolve("editor.reviewers"),
			desc = "reviewers",
			action = function(editor)
				select_reviewers(state, editor)
			end,
		})
	end
	local diff_keys = keymaps.resolve("pulls.open_diff")
	if diff_keys then
		form_keymaps[#form_keymaps + 1] = {
			key = diff_keys,
			desc = "diff",
			action = function(editor)
				preview_diff(state, editor)
			end,
		}
	end

	local editor = form.open({
		header = "Create Pull Request",
		initial_title = content.title,
		initial_body = content.body,
		completion = {
			context = { provider = state.repository.provider, repository = state.repo_slug },
		},
		meta = function()
			return render_meta(state)
		end,
		submit = function(current)
			submit(state, current)
		end,
		close = function(current)
			if not state.submitting then
				form.close(current)
			end
		end,
		on_closed = function()
			state.requests.cancel()
			utils.buffer.delete(state.commits_buf)
		end,
		keymaps = form_keymaps,
	})
	open_commits(state, editor, content)
	return editor
end

---@return AtlasRequestScope
function M.open()
	local scope = requests.new()
	notify.loading("Preparing pull request...")

	scope.run(function(done)
		return git.repo_root(nil, done)
	end, function(root, err)
		if err then
			notify.error(err)
			return
		end

		scope.all({
			repository = function(done)
				return git.local_repository(root, done)
			end,
			head = function(done)
				return git.current_branch(root, done)
			end,
			base = function(done)
				return git.default_branch(root, "origin", done)
			end,
			branches = function(done)
				return git.list_remote_branches(root, "origin", done)
			end,
		}, function(values, errors)
			local load_err = errors.repository or errors.head or errors.base or errors.branches
			if load_err then
				notify.error(load_err)
				return
			end

			local repository = values.repository
			local provider = providers.load(repository.provider, "pulls")
			local write = provider and provider.capabilities.write
			if not write or not write.create then
				notify.error("Provider does not support creating pull requests: " .. repository.provider)
				return
			end

			local loads = {
				content = function(done)
					return description.build(
						root,
						repository.repo_full_name,
						values.base,
						values.head,
						repository,
						done
					)
				end,
			}
			if write.fetch_reviewer_candidates then
				loads.reviewers = function(done)
					return write.fetch_reviewer_candidates({
						repo_slug = repository.repo_full_name,
					}, done)
				end
			end

			scope.all(loads, function(loaded, load_errors)
				local content_err = load_errors.content or load_errors.reviewers
				if content_err then
					notify.error(content_err)
					return
				end

				local candidates = loaded.reviewers or {}
				local reviewers = vim.tbl_filter(function(reviewer)
					return reviewer.selected
				end, candidates)
				local branches = vim.tbl_filter(function(branch)
					return branch ~= values.head
				end, values.branches)
				if values.base ~= values.head and not vim.tbl_contains(branches, values.base) then
					table.insert(branches, 1, values.base)
				end

				---@type PullsCreatePRState
				local state = {
					repo_root = root,
					repo_slug = repository.repo_full_name,
					repository = repository,
					head = values.head,
					base = values.base,
					draft = false,
					branches = branches,
					reviewer_candidates = candidates,
					reviewers = reviewers,
					commits_buf = vim.api.nvim_create_buf(false, true),
					requests = requests.new(),
					loading = false,
					submitting = false,
					write = write,
				}

				notify.clear()
				open_editor(state, loaded.content)
			end)
		end)
	end)

	return scope
end

return M
