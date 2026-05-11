local M = {}

local editor = require("atlas.ui.popups.editor")
local git_branch = require("atlas.core.git")
local config = require("atlas.config")
local spinner = require("atlas.ui.popups.spinner")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local multi_select = require("atlas.ui.popups.multi_select")

local DEFAULT_GITHUB_PR_TEMPLATE = ".github/pull_request_template.md"

---@class CreatePRLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class CreatePRFields
---@field repo_slug string         -- "owner/repo"
---@field repo_root string         -- absolute path to local repo
---@field provider PullsProvider|nil
---@field head string              -- source branch
---@field base string              -- destination branch
---@field title string
---@field body string
---@field draft boolean
---@field commit_count integer
---@field available_bases string[]
---@field reviewers PullsCreatePRReviewer[]|"loading"|string candidates with .selected toggled by user, or "loading", or an error message string

---@class CreatePRState
---@field fields CreatePRFields
---@field layout CreatePRLayout
---@field content_width integer
---@field is_submitting boolean

local function notify(level, msg)
	vim.notify("[Atlas] " .. tostring(msg), level)
end

local function notify_info(msg)
	notify(vim.log.levels.INFO, msg)
end

local function notify_warn(msg)
	notify(vim.log.levels.WARN, msg)
end

local function notify_error(msg)
	notify(vim.log.levels.ERROR, msg)
end

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return vim.trim(value)
end

---@param root string
---@param repo_slug string
---@return string
local function read_configured_pr_template(root, repo_slug)
	local pulls = (config.options or {}).pulls or {}
	local repo_config = pulls.repo_config or {}
	local settings = repo_config.settings or {}
	local repo_settings = settings[repo_slug]
	if type(repo_settings) ~= "table" then
		repo_settings = {}
	end

	local template_path = type(repo_settings.pr_template) == "string" and trim(repo_settings.pr_template)
		or DEFAULT_GITHUB_PR_TEMPLATE
	if template_path == "" then
		return ""
	end

	local path = root .. "/" .. template_path
	if vim.fn.filereadable(path) ~= 1 then
		return ""
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return ""
	end
	return table.concat(lines, "\n")
end

---@param root string
---@param repo_slug string
---@param base string
---@param head string
---@return string title
---@return string body
---@return integer commit_count
local function build_pr_content(root, repo_slug, base, head)
	local commits = git_branch.commits_for_range(root, git_branch.commit_range(root, base, head))
	local latest_commit = commits[#commits]
	local title = latest_commit and latest_commit.subject or ""

	local template = trim(read_configured_pr_template(root, repo_slug))
	if template ~= "" then
		return title, template, #commits
	end

	local commit_lines = {}
	for _, commit in ipairs(commits) do
		table.insert(commit_lines, string.format("- `%s` %s", commit.hash, commit.subject))
	end

	return title, table.concat(commit_lines, "\n"), #commits
end

---@param provider_id "github"|"bitbucket"
---@return PullsProvider|nil, string|nil
local function load_provider(provider_id)
	local ok, mod
	if provider_id == "github" then
		ok, mod = pcall(require, "atlas.pulls.providers.github")
	elseif provider_id == "bitbucket" then
		ok, mod = pcall(require, "atlas.pulls.providers.bitbucket")
	else
		return nil, "Unsupported provider: " .. tostring(provider_id)
	end

	if not ok or type(mod) ~= "table" then
		return nil, "Failed to load provider: " .. tostring(provider_id)
	end
	return mod, nil
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

	local labels = {}
	for _, reviewer in ipairs(selected) do
		table.insert(labels, reviewer.label)
	end
	return table.concat(labels, ", ")
end

---@param pr_state CreatePRState
---@return EditorPopupMetaRow[]
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

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param pr_state CreatePRState
local function get_title(pr_state)
	if not valid_buf(pr_state.layout.title_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(pr_state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

---@param pr_state CreatePRState
local function get_body(pr_state)
	if not valid_buf(pr_state.layout.desc_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(pr_state.layout.desc_buf, 0, -1, false), "\n")
end

---@param pr_state CreatePRState
local function render_meta(pr_state)
	editor.render_meta(pr_state, meta_rows(pr_state))
end

---@param pr_state CreatePRState
local function close(pr_state)
	spinner.stop()
	editor.close(pr_state.layout)
end

---@param pr_state CreatePRState
local function confirm_close(pr_state)
	local title = get_title(pr_state)
	local body = get_body(pr_state)
	if title == "" and body == "" then
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
	if type(choices) ~= "table" or #choices == 0 then
		notify_warn("No base branches available")
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
		notify_warn("Reviewers unavailable: " .. reviewers)
		return
	end
	if #reviewers == 0 then
		notify_warn("No reviewers available")
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
	if provider == nil or provider.fetch_default_reviewers == nil then
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

	provider.fetch_default_reviewers({
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
	spinner.stop()
	close(pr_state)

	local url = result and result.url or nil
	if type(url) == "string" and url ~= "" then
		notify_info("PR created: " .. url)
		pcall(vim.fn.setreg, "+", url)
	else
		notify_info("PR created")
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
		notify_warn("Title is required")
		return
	end

	local body = get_body(pr_state)
	local provider = pr_state.fields.provider
	if type(provider) ~= "table" or type(provider.create_pr) ~= "function" then
		notify_error("Provider does not support PR creation")
		return
	end

	if pr_state.fields.head == "" or pr_state.fields.base == "" then
		notify_warn("Head and base branches are required")
		return
	end

	if pr_state.fields.head == pr_state.fields.base then
		notify_warn("Head and base branches must differ")
		return
	end

	pr_state.is_submitting = true
	spinner.start("Creating pull request…")

	local selected_reviewers = {}
	if type(pr_state.fields.reviewers) == "table" then
		for _, reviewer in ipairs(pr_state.fields.reviewers) do
			if reviewer.selected then
				table.insert(selected_reviewers, reviewer)
			end
		end
	end

	local function do_create()
		spinner.start("Creating pull request…")
		provider.create_pr({
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
					spinner.stop()
					notify_error("Create PR failed: " .. tostring(err))
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

	spinner.start("Pushing " .. pr_state.fields.head .. " to origin…")
	git_branch.push_branch(pr_state.fields.repo_root, pr_state.fields.head, "origin", function(ok, push_err)
		if not ok then
			pr_state.is_submitting = false
			spinner.stop()
			notify_error("git push failed: " .. tostring(push_err or ""))
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
			title = opts.initial_title,
			body = opts.initial_body,
			draft = opts.draft,
			commit_count = opts.commit_count,
			available_bases = type(opts.available_bases) == "table" and opts.available_bases or { opts.base },
			reviewers = "loading",
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
	}

	editor.open(pr_state, {
		title = " Create Pull Request ",
		min_height = 20,
		meta_height = 3,
		title_winbar = "Title",
		desc_winbar = "Description",
		initial_title = pr_state.fields.title,
		initial_body = pr_state.fields.body,
		close = function()
			confirm_close(pr_state)
		end,
		submit = function()
			submit(pr_state)
		end,
		meta = function()
			return meta_rows(pr_state)
		end,
		keymaps = {
			{
				key = "gb",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "base",
				show_in_footer = true,
				action = function()
					pick_base(pr_state, function()
						render_meta(pr_state)
					end)
				end,
			},
			{
				key = "gd",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "toggle draft",
				show_in_footer = true,
				action = function()
					pr_state.fields.draft = not pr_state.fields.draft
					render_meta(pr_state)
				end,
			},
			{
				key = "gr",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "reviewers",
				show_in_footer = true,
				action = function()
					pick_reviewers(pr_state, function()
						render_meta(pr_state)
					end)
				end,
			},
		},
	})

	load_reviewers(pr_state, function()
		render_meta(pr_state)
	end)
end

function M.start()
	local root, root_err = git_branch.repo_root(nil)
	if not root then
		notify_error(root_err or "Not in a git repository")
		return
	end

	local head, head_err = git_branch.current_branch(root)
	if not head then
		notify_error(head_err or "Could not detect current branch")
		return
	end

	local remote_url, remote_err = git_branch.remote_url(root, "origin")
	if not remote_url then
		notify_error(remote_err or "No origin remote configured")
		return
	end

	local info, parse_err = git_branch.parse_remote_url(remote_url)
	if not info then
		notify_error(parse_err or "Could not parse remote URL")
		return
	end
	if info.provider == "unknown" then
		notify_error("Unsupported remote host: " .. info.host)
		return
	end

	local provider, provider_err = load_provider(info.provider)
	if not provider then
		notify_error(provider_err or "Provider unavailable")
		return
	end
	if type(provider.create_pr) ~= "function" then
		notify_error("Provider " .. info.provider .. " does not support PR creation")
		return
	end

	local base = git_branch.default_branch(root, "origin") or "main"

	if head == base then
		notify_warn(string.format("HEAD '%s' is the default branch — switch to a feature branch first", head))
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

	local default_title, default_body, commit_count = build_pr_content(root, info.slug, base, head)

	M.open({
		provider = provider,
		repo_slug = info.slug,
		repo_root = root,
		head = head,
		base = base,
		available_bases = available_bases,
		initial_title = default_title,
		initial_body = default_body,
		draft = false,
		commit_count = commit_count,
	})
end

return M
