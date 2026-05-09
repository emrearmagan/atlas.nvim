local M = {}

local layout = require("atlas.pulls.ui.create_pr.layout")
local state = require("atlas.pulls.ui.create_pr.state")
local git_branch = require("atlas.core.git")
local config = require("atlas.config")
local spinner = require("atlas.ui.popups.spinner")

local DEFAULT_GITHUB_PR_TEMPLATE = ".github/pull_request_template.md"

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

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function get_title()
	if not valid_buf(state.layout.title_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

local function get_body()
	if not valid_buf(state.layout.desc_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(state.layout.desc_buf, 0, -1, false), "\n")
end

local function close()
	spinner.stop()
	layout.close(state.layout)
	state.reset()
end

local function confirm_close()
	local title = get_title()
	local body = get_body()
	if title == "" and body == "" then
		close()
		return
	end

	vim.ui.input({ prompt = "Discard pull request draft? [y/N]: " }, function(input)
		if type(input) == "string" and input:match("^[yY]") then
			close()
		end
	end)
end

---@param on_change fun()
local function pick_base(on_change)
	local choices = state.fields.available_bases
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
		state.fields.base = choice
		on_change()
	end)
end

---@param result PullsCreatePRResult
local function on_success(result)
	state.is_submitting = false
	spinner.stop()
	close()

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

local function submit()
	if state.is_submitting then
		return
	end

	local title = get_title()
	if title == "" then
		notify_warn("Title is required")
		return
	end

	local body = get_body()
	local provider = state.fields.provider
	if type(provider) ~= "table" or type(provider.create_pr) ~= "function" then
		notify_error("Provider does not support PR creation")
		return
	end

	if state.fields.head == "" or state.fields.base == "" then
		notify_warn("Head and base branches are required")
		return
	end

	if state.fields.head == state.fields.base then
		notify_warn("Head and base branches must differ")
		return
	end

	state.is_submitting = true
	spinner.start("Creating pull request…")

	local function do_create()
		spinner.start("Creating pull request…")
		provider.create_pr({
			repo_slug = state.fields.repo_slug,
			repo_root = state.fields.repo_root,
			title = title,
			body = body,
			head = state.fields.head,
			base = state.fields.base,
			draft = state.fields.draft,
		}, function(result, err)
			vim.schedule(function()
				if err then
					state.is_submitting = false
					spinner.stop()
					notify_error("Create PR failed: " .. tostring(err))
					return
				end
				on_success(result or {})
			end)
		end)
	end

	-- Make sure the source branch exists on the remote first.
	local has_remote = git_branch.branch_exists_on_remote(state.fields.repo_root, state.fields.head, "origin")
	if has_remote then
		do_create()
		return
	end

	spinner.start("Pushing " .. state.fields.head .. " to origin…")
	git_branch.push_branch(state.fields.repo_root, state.fields.head, "origin", function(ok, push_err)
		if not ok then
			state.is_submitting = false
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

	state.reset()
	state.fields.provider = opts.provider
	state.fields.repo_slug = opts.repo_slug
	state.fields.repo_root = opts.repo_root
	state.fields.head = opts.head
	state.fields.base = opts.base
	state.fields.title = opts.initial_title
	state.fields.body = opts.initial_body
	state.fields.draft = opts.draft
	state.fields.commit_count = opts.commit_count
	state.fields.available_bases = type(opts.available_bases) == "table" and opts.available_bases
		or { state.fields.base }

	layout.open(state)

	layout.setup(state, {
		confirm_close = confirm_close,
		pick_base = pick_base,
		submit = submit,
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == state.layout.title_buf then
			vim.cmd("startinsert!")
		end
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
