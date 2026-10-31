local M = {}

local form = require("atlas.ui.form")
local keymaps = require("atlas.core.keymaps")
local meta = require("atlas.pulls.editor.meta")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local presentation = require("atlas.pulls.ui.presentation")
local requests = require("atlas.core.requests")

---@class PullsEditPRState
---@field provider PullsProvider
---@field write PullsWriteCapability
---@field pr PullRequest
---@field details PullRequestDetails
---@field reviewers PullsReviewer[]
---@field reviewer_selection PullsReviewerCandidate[]|nil
---@field initial_reviewer_ids string[]|nil
---@field assignees AtlasUser[]
---@field labels PullsLabel[]
---@field base PullsRef
---@field draft boolean
---@field requests AtlasRequestScope
---@field loading "base"|"reviewers"|"assignees"|"labels"|"diff"|nil
---@field submitting boolean
---@field on_done (fun(changed: boolean, err: string|nil))|nil

---@param items table[]
---@param key string
---@return string[]
local function sorted_values(items, key)
	local values = {}
	for _, item in ipairs(items) do
		values[#values + 1] = item[key]
	end
	table.sort(values)
	return values
end

---@param state PullsEditPRState
---@param editor AtlasForm
---@return boolean
local function is_modified(state, editor)
	local content = form.get_content(editor)
	return vim.trim(content.title) ~= state.pr.title
		or content.body ~= state.details.description
		or state.base.branch ~= state.pr.destination.branch
		or state.draft ~= (state.pr.state == "draft")
		or not vim.deep_equal(sorted_values(state.labels, "name"), sorted_values(state.details.labels or {}, "name"))
		or not vim.deep_equal(
			sorted_values(state.assignees, "username"),
			sorted_values(state.details.assignees or {}, "username")
		)
		or (
			state.reviewer_selection ~= nil
			and not vim.deep_equal(sorted_values(state.reviewer_selection, "provider_id"), state.initial_reviewer_ids)
		)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function select_base(state, editor)
	if state.loading or state.submitting then
		return
	end
	state.loading = "base"
	editor.statusline:notify("loading", "Loading target branches...")
	form.render_meta(editor)
	local branches = {}

	local function fetch_page(cursor)
		state.requests.run(function(done)
			return state.provider.capabilities.repository.fetch_branches(state.pr.repo, { cursor = cursor }, done)
		end, function(items, err, next_cursor)
			if err then
				state.loading = nil
				form.render_meta(editor)
				editor.statusline:notify("error", err)
				return
			end
			vim.list_extend(branches, items)
			if next_cursor then
				fetch_page(next_cursor)
				return
			end

			state.loading = nil
			form.render_meta(editor)
			editor.statusline:clear_notice()
			local initial_index
			for i, branch in ipairs(branches) do
				if branch.name == state.base.branch then
					initial_index = i
					break
				end
			end
			picker.select({
				title = "Target branch",
				items = branches,
				initial_index = initial_index,
				format_item = function(branch)
					return branch.name
				end,
				on_select = function(branch)
					if branch and not editor.closed and not state.submitting then
						state.base = {
							branch = branch.name,
							commit_hash = branch.hash,
							https_url = state.pr.destination.https_url,
							ssh_url = state.pr.destination.ssh_url,
						}
						form.render_meta(editor)
					end
				end,
			})
		end)
	end
	fetch_page(nil)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function select_reviewers(state, editor)
	if state.loading or state.submitting then
		return
	end
	state.loading = "reviewers"
	editor.statusline:notify("loading", "Loading reviewers...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return state.write.fetch_reviewer_candidates({
			repo_slug = state.pr.repo_full_name,
			pr = state.pr,
		}, done)
	end, function(items, err)
		state.loading = nil
		if err then
			form.render_meta(editor)
			editor.statusline:notify("warn", err)
			return
		end
		if #items == 0 then
			form.render_meta(editor)
			editor.statusline:notify("warn", "No reviewer candidates available")
			return
		end
		if not state.reviewer_selection then
			state.reviewer_selection = vim.tbl_filter(function(reviewer)
				return reviewer.selected
			end, items)
			state.initial_reviewer_ids = sorted_values(state.reviewer_selection, "provider_id")
		end
		form.render_meta(editor)
		editor.statusline:clear_notice()
		picker.multi_select({
			title = "Reviewers",
			items = items,
			selected = state.reviewer_selection,
			key = function(reviewer)
				return reviewer.provider_id
			end,
			format_item = function(reviewer)
				return reviewer.label
			end,
			on_done = function(selected)
				if not editor.closed and not state.submitting then
					state.reviewer_selection = selected
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function select_assignees(state, editor)
	if state.loading or state.submitting then
		return
	end
	state.loading = "assignees"
	editor.statusline:notify("loading", "Loading assignees...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return state.write.fetch_assignees(state.pr.repo_full_name, done)
	end, function(items, err)
		state.loading = nil
		form.render_meta(editor)
		if err then
			editor.statusline:notify("error", err)
			return
		end
		editor.statusline:clear_notice()
		picker.multi_select({
			title = "Assignees",
			items = items,
			selected = state.assignees,
			key = function(user)
				return user.username
			end,
			format_item = function(user)
				return "@" .. user.username .. " - " .. user.name
			end,
			on_done = function(selected)
				if not editor.closed and not state.submitting then
					state.assignees = selected
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function select_labels(state, editor)
	if state.loading or state.submitting then
		return
	end
	state.loading = "labels"
	editor.statusline:notify("loading", "Loading labels...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return state.write.fetch_labels(state.pr.repo_full_name, done)
	end, function(items, err)
		state.loading = nil
		form.render_meta(editor)
		if err then
			editor.statusline:notify("error", err)
			return
		end
		editor.statusline:clear_notice()
		picker.multi_select({
			title = "Labels",
			items = items,
			selected = state.labels,
			key = function(label)
				return label.name
			end,
			format_item = function(label)
				return label.name
			end,
			on_done = function(selected)
				if not editor.closed and not state.submitting then
					state.labels = selected
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function preview_diff(state, editor)
	if state.loading or state.submitting then
		return
	end
	if state.base.branch == state.pr.destination.branch then
		require("atlas.pulls.diff").open_pr(state.pr)
		return
	end

	local pr = vim.tbl_extend("force", {}, state.pr, { destination = state.base })
	state.loading = "diff"
	editor.statusline:notify("loading", "Preparing diff...")
	state.requests.run(function(done)
		return require("atlas.core.git.checkout").prepare_diff(pr, nil, function(message)
			if not editor.closed then
				editor.statusline:notify("loading", message)
			end
		end, done)
	end, function(source, err)
		state.loading = nil
		if err then
			editor.statusline:notify("error", err)
			return
		end
		editor.statusline:clear_notice()
		require("atlas.pulls.diff").open_range({
			root = source.root,
			base = source.base_revision,
			head = source.head_revision,
		})
	end)
end

---@param state PullsEditPRState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end
	if state.loading then
		editor.statusline:notify("warn", "Wait for loading to finish")
		return
	end

	local content = form.get_content(editor)
	local title = vim.trim(content.title)
	if title == "" then
		editor.statusline:notify("warn", "Title is required")
		return
	end
	if not is_modified(state, editor) then
		form.close(editor)
		notify.info("No changes")
		return
	end

	local write = state.write
	local opts = {
		title = title,
		body = content.body,
		labels = write.fetch_labels and sorted_values(state.labels, "name") or nil,
		assignees = write.fetch_assignees and state.assignees or nil,
	}
	if state.pr.state == "open" or state.pr.state == "draft" then
		opts.base = state.base.branch
		opts.draft = state.draft
		opts.reviewers = state.reviewer_selection
	end

	state.submitting = true
	vim.bo[editor.editor_buf].modifiable = false
	editor.statusline:notify("loading", "Saving pull request...")
	write.update(vim.tbl_extend("force", {}, state.pr), opts, function(ok, err)
		if not ok then
			---@cast err string
			state.submitting = false
			if editor.closed then
				if state.on_done then
					state.on_done(false, err)
				end
				notify.error(err)
			else
				vim.bo[editor.editor_buf].modifiable = true
				editor.statusline:notify("error", err)
			end
			return
		end

		form.close(editor)
		state.submitting = false
		if state.on_done then
			state.on_done(true, nil)
		end
		notify.info("PR updated", { vim_notify = true })
	end)
end

---@param state PullsEditPRState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local pr, details = state.pr, state.details
	local reviewer_names = {}
	if state.reviewer_selection then
		for _, reviewer in ipairs(state.reviewer_selection) do
			reviewer_names[#reviewer_names + 1] = reviewer.label
		end
	else
		for _, reviewer in ipairs(state.reviewers) do
			if reviewer.role == "reviewer" then
				reviewer_names[#reviewer_names + 1] = "@" .. presentation.user_handle(reviewer)
			end
		end
	end
	local author = presentation.user_handle(pr.author)
	local status = pr.state
	if status == "open" or status == "draft" then
		status = state.draft and "draft" or "open"
	end
	local reviewers = meta.people("Reviewers:", reviewer_names, "None")
	reviewers.loading = state.loading == "reviewers"

	local rows = {
		{ { key = "Repo:", value = pr.repo_full_name, hl = presentation.repo_hl(pr.repo_full_name) } },
		{
			{ key = "Head:", value = pr.source.branch },
			{ key = "Base:", value = state.base.branch, loading = state.loading == "base" },
		},
		{
			{
				key = "State:",
				value = status,
				spans = { { start_col = 0, end_col = #status, hl_group = presentation.pr_state_hl(status) } },
			},
			{ key = "Author:", value = "@" .. author, hl = presentation.author_hl(author) },
		},
		{ reviewers },
	}
	if details.assignees then
		local assignees = vim.tbl_map(function(user)
			return "@" .. presentation.user_handle(user)
		end, state.assignees)
		local field = meta.people("Assignees:", assignees, "Unassigned")
		field.loading = state.loading == "assignees"
		rows[#rows + 1] = { field }
	end
	if details.labels then
		local field = meta.labels(state.labels)
		field.loading = state.loading == "labels"
		rows[#rows + 1] = { field }
	end
	return rows
end

---@param state PullsEditPRState
---@return AtlasForm
local function open_editor(state)
	local write = state.write
	local form_keymaps = {}
	if state.pr.state == "open" or state.pr.state == "draft" then
		if state.provider.capabilities.repository then
			form_keymaps[#form_keymaps + 1] = {
				key = "gb",
				desc = "base",
				action = function(editor)
					select_base(state, editor)
				end,
			}
		end
		if write.fetch_reviewer_candidates then
			form_keymaps[#form_keymaps + 1] = {
				key = "gr",
				desc = "reviewers",
				action = function(editor)
					select_reviewers(state, editor)
				end,
			}
		end
		form_keymaps[#form_keymaps + 1] = {
			key = "gD",
			desc = "draft",
			action = function(editor)
				if state.submitting then
					return
				end
				state.draft = not state.draft
				form.render_meta(editor)
			end,
		}
	end
	if write.fetch_assignees then
		form_keymaps[#form_keymaps + 1] = {
			key = "ga",
			desc = "assignees",
			action = function(editor)
				select_assignees(state, editor)
			end,
		}
	end
	if write.fetch_labels then
		form_keymaps[#form_keymaps + 1] = {
			key = "gl",
			desc = "labels",
			action = function(editor)
				select_labels(state, editor)
			end,
		}
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

	return form.open({
		header = "Edit PR #" .. state.pr.id,
		initial_title = state.pr.title,
		initial_body = state.details.description,
		completion = {
			context = {
				provider = state.provider.id,
				repository = state.pr.repo_full_name,
				pr = { id = state.pr.id, repo_full_name = state.pr.repo_full_name },
			},
		},
		is_modified = function(editor)
			return is_modified(state, editor)
		end,
		meta = function()
			return render_meta(state)
		end,
		submit = function(editor)
			submit(state, editor)
		end,
		close = function(editor)
			if not state.submitting then
				form.close(editor)
			end
		end,
		on_closed = function()
			state.requests.cancel()
			if not state.submitting and state.on_done then
				state.on_done(false, nil)
			end
		end,
		keymaps = form_keymaps,
	})
end

---@param provider PullsProvider
---@param pr PullRequest
---@param on_done (fun(changed: boolean, err: string|nil))|nil
---@return AtlasRequestScope
function M.open(provider, pr, on_done)
	local scope = requests.new()
	local write = provider.capabilities.write
	if not write or not write.update then
		local err = "Provider does not support editing pull requests: " .. provider.id
		notify.error(err)
		if on_done then
			on_done(false, err)
		end
		return scope
	end
	local core = provider.capabilities.core
	notify.loading("Loading PR #" .. pr.id .. "...")

	scope.all({
		pullrequests = function(done)
			return core.fetch_by_refs({ pr }, { force_refresh = true }, done)
		end,
		details = function(done)
			return core.fetch_pullrequest(pr, { force_refresh = true }, done)
		end,
		reviewers = function(done)
			return core.fetch_reviewers(pr, { force_refresh = true }, done)
		end,
	}, function(values, errors)
		local current = values.pullrequests and values.pullrequests[1]
		local err = errors.pullrequests or errors.details or errors.reviewers
		if err or not current then
			err = err or "Pull request not found"
			notify.error(err)
			if on_done then
				on_done(false, err)
			end
			return
		end

		---@type PullsEditPRState
		local state = {
			provider = provider,
			write = write,
			pr = current,
			details = values.details,
			reviewers = values.reviewers,
			assignees = values.details.assignees or {},
			labels = values.details.labels or {},
			base = current.destination,
			draft = current.state == "draft",
			requests = requests.new(),
			submitting = false,
			on_done = on_done,
		}

		notify.clear()
		open_editor(state)
	end)

	return scope
end

return M
