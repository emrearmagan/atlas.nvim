local M = {}

local form = require("atlas.ui.popups.form")
local git_branch = require("atlas.core.git")
local keymaps = require("atlas.core.keymaps")
local description = require("atlas.pulls.create.description")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local multi_select = require("atlas.ui.popups.multi_select")
local notify = require("atlas.core.notify")

---@class CreatePRFields
---@field repo_slug string         -- "owner/repo"
---@field repo_root string         -- absolute path to local repo
---@field provider PullsProvider|nil
---@field head string              -- source branch
---@field base string              -- destination branch
---@field draft boolean
---@field commit_count integer
---@field commits { hash: string, subject: string }[]
---@field diffstat string[]
---@field available_bases string[]
---@field reviewers PullsCreatePRReviewer[]|"loading"|string candidates with .selected toggled by user, or "loading", or an error message string

---@class CreatePRState
---@field fields CreatePRFields
---@field layout AtlasFormLayout
---@field content_width integer
---@field is_submitting boolean
---@field settings_changed boolean
---@field initial_body string

---@param provider_id string
---@return PullsProvider|nil, string|nil
local function load_provider(provider_id)
	local provider = require("atlas.providers").load(provider_id, "pulls")
	if provider == nil then
		return nil, "Unsupported provider: " .. tostring(provider_id)
	end
	---@cast provider PullsProvider
	return provider, nil
end

---@param pr_state CreatePRState
---@return string
local function reviewers_value(pr_state)
	local reviewers = pr_state.fields.reviewers
	if reviewers == "loading" then
		return require("atlas.ui.components.spinner").with_text("Loading...")
	end
	if type(reviewers) == "string" then
		return "unavailable"
	end

	if #reviewers == 0 then
		return "no reviewers available"
	end

	local selected = {}
	for _, reviewer in ipairs(reviewers) do
		if reviewer.selected then
			table.insert(selected, reviewer)
		end
	end

	if #selected == 0 then
		return "no reviewers"
	end

	if #selected == #reviewers then
		local all_default = true
		for _, reviewer in ipairs(reviewers) do
			if not reviewer.default then
				all_default = false
				break
			end
		end
		return all_default and "all default reviewers" or "all reviewers"
	end

	if #selected > 2 then
		return string.format("%d reviewers", #selected)
	end

	local labels = vim.tbl_map(function(reviewer)
		return reviewer.label
	end, selected)
	return table.concat(labels, ", ")
end

---@param pr_state CreatePRState
---@return AtlasFormMetaRow[]
local function meta_rows(pr_state)
	local repo = tostring(pr_state.fields.repo_slug or "")
	local head = tostring(pr_state.fields.head or "")
	local base = tostring(pr_state.fields.base or "")
	local draft = pr_state.fields.draft == true
	local commit_count = tonumber(pr_state.fields.commit_count) or 0

	local branch_value = string.format("%s → %s", head, base)
	local status = draft and "DRAFT" or "READY"
	local status_hl = draft and pulls_helper.pr_state_hl("draft") or pulls_helper.pr_state_hl("open")
	local commit_label = commit_count == 1 and "1 commit" or string.format("%d commits", commit_count)

	return {
		{ "Repo:", { text = repo, hl = pulls_helper.repo_hl(repo) }, "Status:", { text = status, hl = status_hl } },
		{ "Branch:", branch_value, "Commits:", commit_label },
		{ "Reviewers:", reviewers_value(pr_state), "", "" },
	}
end

---@param pr_state CreatePRState
---@return string[]
local function commit_context(pr_state)
	local lines = vim.tbl_map(function(commit)
		return string.format("%s  %s", commit.hash, commit.subject)
	end, pr_state.fields.commits)
	if #lines == 0 then
		table.insert(lines, "No commits")
	end
	if #pr_state.fields.diffstat > 0 then
		table.insert(lines, "")
		vim.list_extend(lines, pr_state.fields.diffstat)
	end
	return lines
end

---@param pr_state CreatePRState
local function refresh_commits(pr_state)
	local replace_body = form.get_body(pr_state.layout) == pr_state.initial_body
	local content, err = description.build(
		pr_state.fields.repo_root,
		pr_state.fields.repo_slug,
		pr_state.fields.base,
		pr_state.fields.head
	)
	if not content then
		form.notify("error", err or "Unable to build pull request description")
		return
	end
	pr_state.fields.commits = content.commits
	pr_state.fields.commit_count = #content.commits
	pr_state.fields.diffstat = content.diffstat
	if replace_body then
		pr_state.initial_body = content.body
		form.set_body(pr_state.layout, content.body)
	end
	form.render_context(pr_state, commit_context(pr_state))
end

---@param pr_state CreatePRState
local function preview_diff(pr_state)
	local base, head, err =
		git_branch.diff_revisions(pr_state.fields.repo_root, pr_state.fields.base, pr_state.fields.head)
	if not base or not head then
		form.notify("error", err or "Unable to resolve diff revisions")
		return
	end
	require("atlas.pulls.actions").open_diff_range({
		git_root = pr_state.fields.repo_root,
		base_revision = base,
		head_revision = head,
	}, function(open_err)
		if open_err then
			form.notify("error", "Unable to open diff: " .. tostring(open_err))
		end
	end)
end

---@param pr_state CreatePRState
local function get_title(pr_state)
	return vim.trim(form.get_title(pr_state.layout))
end

---@param pr_state CreatePRState
local function get_body(pr_state)
	return form.get_body(pr_state.layout)
end

---@param pr_state CreatePRState
local function render_meta(pr_state)
	form.render_meta(pr_state, meta_rows(pr_state))
end

---@param pr_state CreatePRState
local function close(pr_state)
	form.close(pr_state.layout)
end

---@param pr_state CreatePRState
local function confirm_close(pr_state)
	local title = get_title(pr_state)
	local body = get_body(pr_state)
	if not pr_state.settings_changed and title == "" and body == "" then
		close(pr_state)
		return
	end

	vim.ui.input({ prompt = "Discard pull request draft? [y/N]: " }, function(input)
		if type(input) == "string" and input:match("^[yY]") then
			close(pr_state)
		end
	end)
end

---@param on_change fun()
---@param pr_state CreatePRState
local function pick_base(pr_state, on_change)
	local choices = pr_state.fields.available_bases
	if #choices == 0 then
		form.notify("warn", "No base branches available")
		return
	end

	vim.ui.select(choices, {
		prompt = "Select base branch:",
	}, function(choice)
		if type(choice) ~= "string" or choice == "" then
			return
		end
		pr_state.fields.base = choice
		on_change()
	end)
end

---@param pr_state CreatePRState
---@param on_change fun()
local function pick_reviewers(pr_state, on_change)
	local reviewers = pr_state.fields.reviewers
	if reviewers == "loading" then
		return
	end
	if type(reviewers) == "string" then
		form.notify("warn", "Reviewers unavailable: " .. reviewers)
		return
	end
	if #reviewers == 0 then
		form.notify("warn", "No reviewers available")
		return
	end

	local selected = {}
	for _, reviewer in ipairs(reviewers) do
		if reviewer.selected then
			table.insert(selected, reviewer)
		end
	end

	local function sync_selection(current)
		local lookup = {}
		for _, r in ipairs(current) do
			lookup[r.provider_id] = true
		end
		for _, r in ipairs(reviewers) do
			r.selected = lookup[r.provider_id] == true
		end
		on_change()
	end

	multi_select.open({
		items = reviewers,
		selected = selected,
		key = function(item)
			return item.provider_id
		end,
		format = function(item)
			return item.label
		end,
		prompt = "Reviewers:",
		on_change = sync_selection,
		on_done = sync_selection,
	})
end

---@param pr_state CreatePRState
---@param on_change fun()
local function load_reviewers(pr_state, on_change)
	local provider = pr_state.fields.provider
	local create = provider and provider.capabilities.create
	if create == nil or create.fetch_default_reviewers == nil then
		pr_state.fields.reviewers = {}
		return
	end

	pr_state.fields.reviewers = "loading"

	local spinner_timer = vim.loop.new_timer()
	if spinner_timer ~= nil then
		spinner_timer:start(
			100,
			100,
			vim.schedule_wrap(function()
				if pr_state.fields.reviewers ~= "loading" then
					spinner_timer:stop()
					spinner_timer:close()
					return
				end
				on_change()
			end)
		)
	end

	create.fetch_default_reviewers({
		repo_slug = pr_state.fields.repo_slug,
		repo_root = pr_state.fields.repo_root,
		head = pr_state.fields.head,
		base = pr_state.fields.base,
	}, function(reviewers, err)
		vim.schedule(function()
			if err then
				pr_state.fields.reviewers = tostring(err)
			else
				pr_state.fields.reviewers = reviewers or {}
			end
			on_change()
		end)
	end)
end

---@param pr_state CreatePRState
---@param result PullsCreatePRResult
local function on_success(pr_state, result)
	pr_state.is_submitting = false
	close(pr_state)

	local url = result and result.url or nil
	if type(url) == "string" and url ~= "" then
		notify.info("PR created: " .. url)
		pcall(vim.fn.setreg, "+", url)
	else
		notify.info("PR created")
	end

	-- Refresh the main pulls UI (if open) so the new PR shows up.
	pcall(function()
		require("atlas.pulls.ui.main.controller").refresh_current_view()
	end)
end

---@param pr_state CreatePRState
local function submit(pr_state)
	if pr_state.is_submitting then
		return
	end

	local title = get_title(pr_state)
	if title == "" then
		form.notify("warn", "Title is required")
		return
	end

	local body = get_body(pr_state)
	local provider = pr_state.fields.provider
	local create = provider and provider.capabilities.create
	if not create then
		form.notify("error", "Provider does not support PR creation")
		return
	end

	if pr_state.fields.head == "" or pr_state.fields.base == "" then
		form.notify("warn", "Head and base branches are required")
		return
	end

	if pr_state.fields.head == pr_state.fields.base then
		form.notify("warn", "Head and base branches must differ")
		return
	end

	pr_state.is_submitting = true

	local selected_reviewers = {}
	if type(pr_state.fields.reviewers) == "table" then
		for _, reviewer in ipairs(pr_state.fields.reviewers) do
			if reviewer.selected then
				table.insert(selected_reviewers, reviewer)
			end
		end
	end

	local function do_create()
		form.notify("loading", "Creating pull request...")
		create.create_pr({
			repo_slug = pr_state.fields.repo_slug,
			repo_root = pr_state.fields.repo_root,
			title = title,
			body = body,
			head = pr_state.fields.head,
			base = pr_state.fields.base,
			draft = pr_state.fields.draft,
			reviewers = selected_reviewers,
		}, function(result, err)
			vim.schedule(function()
				if err then
					pr_state.is_submitting = false
					form.notify("error", "Create PR failed: " .. tostring(err))
					return
				end
				on_success(pr_state, result or {})
			end)
		end)
	end

	-- Make sure the source branch exists on the remote first.
	local has_remote = git_branch.branch_exists_on_remote(pr_state.fields.repo_root, pr_state.fields.head, "origin")
	if has_remote then
		do_create()
		return
	end

	form.notify("loading", "Pushing " .. pr_state.fields.head .. " to origin...")
	git_branch.push_branch(pr_state.fields.repo_root, pr_state.fields.head, "origin", function(ok, push_err)
		if not ok then
			pr_state.is_submitting = false
			form.notify("error", "git push failed: " .. tostring(push_err or ""))
			return
		end
		do_create()
	end)
end

---@class CreatePROpenOpts
---@field provider PullsProvider
---@field repo_slug string
---@field repo_root string
---@field head string
---@field base string
---@field available_bases string[]|nil
---@field initial_title string
---@field initial_body string
---@field draft boolean
---@field commit_count integer
---@field commits { hash: string, subject: string }[]|nil
---@field diffstat string[]|nil

---@param opts CreatePROpenOpts
function M.open(opts)
	--- Atlas might not be open when this is called, so we need to load the highlights
	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()

	---@type CreatePRState
	local pr_state = {
		fields = {
			provider = opts.provider,
			repo_slug = opts.repo_slug,
			repo_root = opts.repo_root,
			head = opts.head,
			base = opts.base,
			draft = opts.draft,
			commit_count = opts.commit_count,
			commits = opts.commits or {},
			diffstat = opts.diffstat or {},
			available_bases = opts.available_bases or { opts.base },
			reviewers = "loading",
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		settings_changed = false,
		initial_body = opts.initial_body,
	}

	local form_keymaps = {
		{
			key = "gb",
			mode = "n",
			buffers = { "editor", "context" },
			desc = "base",
			action = function()
				pick_base(pr_state, function()
					pr_state.settings_changed = true
					refresh_commits(pr_state)
					render_meta(pr_state)
				end)
			end,
		},
		{
			key = "gD",
			mode = "n",
			buffers = { "editor", "context" },
			desc = "toggle draft",
			action = function()
				pr_state.fields.draft = not pr_state.fields.draft
				pr_state.settings_changed = true
				render_meta(pr_state)
			end,
		},
		{
			key = "gr",
			mode = "n",
			buffers = { "editor", "context" },
			desc = "reviewers",
			action = function()
				pick_reviewers(pr_state, function()
					pr_state.settings_changed = true
					render_meta(pr_state)
				end)
			end,
		},
	}
	local diff_keys = keymaps.resolve("pulls.open_diff")
	if diff_keys then
		table.insert(form_keymaps, {
			key = #diff_keys == 1 and diff_keys[1] or diff_keys,
			mode = "n",
			buffers = { "editor", "context" },
			desc = "preview diff",
			action = function()
				preview_diff(pr_state)
			end,
		})
	end

	form.open(pr_state, {
		context_title = "Commits",
		context = function()
			return commit_context(pr_state)
		end,
		title_label = "Title",
		body_label = "Description",
		initial_title = opts.initial_title,
		initial_body = opts.initial_body,
		close = function()
			confirm_close(pr_state)
		end,
		submit = function()
			submit(pr_state)
		end,
		meta = function()
			return meta_rows(pr_state)
		end,
		keymaps = form_keymaps,
	})

	load_reviewers(pr_state, function()
		render_meta(pr_state)
	end)
end

function M.start()
	local root, root_err = git_branch.repo_root(nil)
	if not root then
		notify.error(root_err or "Not in a git repository")
		return
	end

	local head, head_err = git_branch.current_branch(root)
	if not head then
		notify.error(head_err or "Could not detect current branch")
		return
	end

	local info = git_branch.local_repository(root)
	if not info then
		notify.error("Could not resolve the origin repository")
		return
	end

	local provider, provider_err = load_provider(info.provider)
	if not provider then
		notify.error(provider_err or "Provider unavailable")
		return
	end
	if not provider.capabilities.create then
		notify.error("Provider " .. info.provider .. " does not support PR creation")
		return
	end

	local base = git_branch.default_branch(root, "origin") or "main"

	if head == base then
		notify.warn(string.format("HEAD '%s' is the default branch — switch to a feature branch first", head))
		return
	end

	local remote_branches = git_branch.list_remote_branches(root, "origin")
	local available_bases = { base }
	local seen = { [base] = true }
	for _, b in ipairs(remote_branches) do
		if not seen[b] and b ~= head then
			seen[b] = true
			table.insert(available_bases, b)
		end
	end

	local initial, description_err = description.build(root, info.slug, base, head)
	if not initial then
		notify.error(description_err or "Unable to build pull request description")
		return
	end

	M.open({
		provider = provider,
		repo_slug = info.slug,
		repo_root = root,
		head = head,
		base = base,
		available_bases = available_bases,
		initial_title = initial.title,
		initial_body = initial.body,
		draft = false,
		commit_count = #initial.commits,
		commits = initial.commits,
		diffstat = initial.diffstat,
	})
end

return M
