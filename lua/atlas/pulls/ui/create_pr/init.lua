local M = {}
local git_branch = require("atlas.core.git.branch")

---@class CreatePRStartOpts
---@field cwd string|nil
---@field initial_title string|nil
---@field initial_body string|nil

---Detect the active git repo from the current buffer / cwd, choose the matching
---provider, gather the source/target branches and open the PR-create editor.
---@param opts CreatePRStartOpts|nil
function M.start(opts)
	opts = opts or {}

	local root, root_err = git_branch.repo_root(opts.cwd)
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

	M.open({
		provider = provider,
		repo_slug = info.slug,
		repo_root = root,
		head = head,
		base = base,
		available_bases = available_bases,
		initial_title = opts.initial_title,
		initial_body = opts.initial_body,
		draft = false,
	})
end

return M
