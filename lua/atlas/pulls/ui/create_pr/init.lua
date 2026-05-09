local M = {}

local layout = require("atlas.pulls.ui.create_pr.layout")
local renderer = require("atlas.pulls.ui.create_pr.renderer")
local state = require("atlas.pulls.ui.create_pr.state")
local git_branch = require("atlas.core.git.branch")
local config = require("atlas.config")
local spinner = require("atlas.ui.popups.spinner")

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
---@param rev string
---@return boolean
local function git_rev_exists(root, rev)
	if root == "" or rev == "" then
		return false
	end
	local res = vim.system({ "git", "-C", root, "rev-parse", "--verify", "--quiet", rev }, { text = true }):wait()
	return res.code == 0
end

---@param root string
---@param base string
---@param head string
---@return string
local function commit_range(root, base, head)
	local remote_base = "origin/" .. base
	if git_rev_exists(root, remote_base) then
		return remote_base .. ".." .. head
	end
	if git_rev_exists(root, base) then
		return base .. ".." .. head
	end
	return head
end

---@param root string
---@param range string
---@return { hash: string, subject: string }[]
local function commits_for_range(root, range)
	local res = vim.system({ "git", "-C", root, "log", "--reverse", "--format=%h %s", range }, { text = true }):wait()
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

---@param commits { hash: string, subject: string }[]
---@return string
local function body_from_commits(commits)
	if #commits == 0 then
		return ""
	end

	local lines = {}
	for _, commit in ipairs(commits) do
		table.insert(lines, string.format("- `%s` %s", commit.hash, commit.subject))
	end
	return table.concat(lines, "\n")
end

---@param root string
---@param provider_id string
---@return string
local function read_configured_pr_template(root, provider_id)
	if provider_id ~= "github" then
		return ""
	end

	local pulls = (config.options or {}).pulls or {}
	local providers = pulls.providers or {}
	local github = providers.github or {}
	local template_path = type(github.pr_template) == "string" and trim(github.pr_template) or ""
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

---@param template string
---@param commits_body string
---@return string
local function combine_body(template, commits_body)
	template = trim(template)
	commits_body = trim(commits_body)

	if template == "" then
		return commits_body
	end
	if commits_body == "" then
		return template
	end
	return template .. "\n\n" .. commits_body
end

---@param root string
---@param provider_id string
---@param base string
---@param head string
---@return string title
---@return string body
local function default_pr_text(root, provider_id, base, head)
	local commits = commits_for_range(root, commit_range(root, base, head))
	local latest_commit = commits[#commits]
	local title = latest_commit and latest_commit.subject or ""
	return title, combine_body(read_configured_pr_template(root, provider_id), body_from_commits(commits))
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

local function toggle_draft()
	state.fields.draft = not state.fields.draft
	renderer.render_meta(state)
end

local function pick_base()
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
		renderer.render_meta(state)
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
---@field initial_title string|nil
---@field initial_body string|nil
---@field draft boolean|nil

---@param opts CreatePROpenOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify_warn("create_pr.open: missing options")
		return
	end

	require("atlas.pulls.ui.highlights").setup()

	state.reset()
	state.fields.provider = opts.provider
	state.fields.repo_slug = tostring(opts.repo_slug or "")
	state.fields.repo_root = tostring(opts.repo_root or "")
	state.fields.head = tostring(opts.head or "")
	state.fields.base = tostring(opts.base or "")
	state.fields.title = tostring(opts.initial_title or "")
	state.fields.draft = opts.draft == true
	state.fields.available_bases = type(opts.available_bases) == "table" and opts.available_bases
		or { state.fields.base }

	layout.open(state)

	if valid_buf(state.layout.desc_buf) and type(opts.initial_body) == "string" and opts.initial_body ~= "" then
		vim.api.nvim_buf_set_lines(
			state.layout.desc_buf,
			0,
			-1,
			false,
			vim.split(opts.initial_body, "\n", { plain = true })
		)
	end

	renderer.render_meta(state)

	layout.setup(state, {
		confirm_close = confirm_close,
		submit = submit,
		pick_base = pick_base,
		toggle_draft = toggle_draft,
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

	-- Build base candidates: default branch + all remote branches (deduped, default first).
	local remote_branches = git_branch.list_remote_branches(root, "origin")
	local available_bases = { base }
	local seen = { [base] = true }
	for _, b in ipairs(remote_branches) do
		if not seen[b] and b ~= head then
			seen[b] = true
			table.insert(available_bases, b)
		end
	end

	local default_title, default_body = default_pr_text(root, info.provider, base, head)

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
	})
end

return M
