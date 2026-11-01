local checkout = require("atlas.core.git.checkout")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local diff = require("atlas.pulls.diff")
local pipelines = require("atlas.pulls.pipelines")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local info = require("atlas.ui.popups.info")
local keymaps = require("atlas.ui.repository.pages.branches.keymaps")
local renderer = require("atlas.ui.repository.pages.branches.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryBranches
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field repository AtlasRepositoryCapability
---@field branches AtlasRepositoryBranch[]|"loading"|string
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field root string|nil
---@field remote string|nil
---@field root_loading boolean
---@field root_error string|nil
---@field root_request AtlasRequestScope
---@field expanded string|nil
---@field commits AtlasGitCommit[]|"loading"|string|nil
---@field commit_request AtlasRequestScope|nil
---@field line_map table<integer, RepositoryBranchSelection>
---@field busy boolean
---@field closed boolean
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field keymaps table<string, AtlasHelpKeyItem[]>

---@class RepositoryBranchSelection
---@field branch AtlasRepositoryBranch
---@field commit AtlasGitCommit|nil

local M = { key = "branches", label = "Branches", icon = icons.get("branch") }
---@type table<integer, RepositoryBranches>
local states = {}

local namespace = vim.api.nvim_create_namespace("atlas.repository.branches")

---@param state RepositoryBranches
---@return RepositoryBranchSelection|nil
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryBranches
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	state.line_map = {}
	local branches = state.branches
	local message
	local hl_group = "AtlasTextMuted"
	if branches == "loading" then
		message = state.spinner:text("Loading branches...")
		hl_group = "Normal"
	elseif type(branches) == "string" then
		message = branches
		hl_group = "AtlasLogError"
	elseif #branches == 0 then
		message = "No branches found"
	end

	if message then
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = hl_group,
		})

		return
	end

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	vim.bo[state.buf].modifiable = false
end

---@param state RepositoryBranches
---@param action string What needs the local repository, e.g. "open diffs"
---@return string|nil
local function local_root(state, action)
	if not state.root then
		local reason = state.root_error and (" (" .. state.root_error .. ")") or ""
		notify.warn(
			state.root_loading and "Resolving local repository..."
				or ("Configure this repository under pulls.repo_config.paths to " .. action .. reason)
		)
	end

	return state.root
end

---@param state RepositoryBranches
local function clear_commits(state)
	if state.commit_request then
		state.commit_request.cancel()
		state.commit_request = nil
	end

	state.expanded = nil
	state.commits = nil
	if not state.busy then
		state.statusline:clear_notice()
	end
end

---@param state RepositoryBranches
---@param branch AtlasRepositoryBranch
local function load_history(state, branch)
	local root = local_root(state, "browse its commits")
	if not root then
		return
	end

	clear_commits(state)
	state.expanded = branch.name
	state.commits = "loading"
	state.statusline:notify("loading", "Loading commits...")
	render(state)
	state.commit_request = checkout.branch_history(root, state.remote, branch, function(result, err)
		if not state.busy then
			state.statusline:clear_notice()
		end

		state.commits = result or err or "Failed to load commits"
		render(state)
	end)
end

---@param state RepositoryBranches
---@param page integer|nil
local function load(state, page)
	if state.busy then
		return
	end

	local repository = state.repository
	local expanded = state.expanded
	clear_commits(state)
	state.requests.cancel()
	state.requests = requests.new()
	state.page = page or 1
	if state.page == 1 then
		state.cursors = {}
	end

	state.next_cursor = nil
	state.branches = "loading"
	state.spinner:start()
	render(state)
	state.statusline:notify("loading", "Loading branches...")
	state.requests.run(function(done)
		return repository.fetch_branches(state.repo, {
			cursor = state.cursors[state.page],
		}, done)
	end, function(branches, err, next_cursor)
		state.spinner:stop()
		state.statusline:clear_notice()
		if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
			return
		end

		state.branches = branches or err or "Failed to load branches"
		state.next_cursor = next_cursor
		state.cursors[state.page + 1] = next_cursor
		render(state)
		if utils.window.valid(state.win) and state.line_map[1] then
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end

		if expanded and branches then
			for _, branch in ipairs(branches) do
				if branch.name == expanded then
					load_history(state, branch)
					break
				end
			end
		end
	end)
end

---@param state RepositoryBranches
local function search(state)
	local repository = state.repository
	if state.busy then
		return
	end

	local branches = state.branches
	picker.search({
		title = "Branches",
		initial_items = type(branches) == "table" and branches or {},
		key = function(branch)
			return branch.name
		end,
		format_item = function(branch)
			return branch.name
		end,
		preview_item = function(branch, done)
			done(renderer.preview(branch))
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_branches(state.repo, { search = query }, finish)
			end, done)
		end,
		on_select = function(branch)
			if not branch or state.closed or not utils.window.valid(state.win) then
				return
			end

			state.requests.cancel()
			state.requests = requests.new()
			for row, entry in pairs(state.line_map) do
				if entry.branch.name == branch.name and not entry.commit then
					vim.api.nvim_set_current_win(state.win)
					vim.api.nvim_win_set_cursor(state.win, { row, 0 })
					return
				end
			end

			clear_commits(state)
			state.page = 1
			state.cursors = {}
			state.next_cursor = nil
			state.branches = { branch }
			state.spinner:stop()
			render(state)
			vim.api.nvim_set_current_win(state.win)
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end,
	})
end

---@param state RepositoryBranches
---@param branch AtlasRepositoryBranch
local function open_pipeline(state, branch)
	local provider = providers.load(state.provider.id, "pulls")
	---@cast provider PullsProvider|nil
	if not provider or not pipelines.get(provider) then
		notify.warn("Pipelines are not available for this provider")
		return
	end

	pipelines.open({
		provider = provider.id,
		repo_full_name = state.repo.full_name,
		target = branch.name,
	}, provider)
end

---@param state RepositoryBranches
local function open_diff(state)
	local selection = current(state)
	if not selection then
		return
	end

	local root = local_root(state, "open diffs")
	if not root then
		return
	end

	local commit = selection.commit
	if commit then
		diff.open_commit({ root = root, commit = commit.hash }, function(err)
			if err then
				notify.error(err)
			end
		end)

		return
	end

	local repository = state.repository
	local branch = selection.branch
	local branches = state.branches
	---@cast branches AtlasRepositoryBranch[]
	local bases = {}
	for _, candidate in ipairs(branches) do
		if candidate.name ~= branch.name then
			table.insert(bases, candidate)
		end
	end

	picker.search({
		title = "Compare " .. branch.name .. " against",
		initial_items = bases,
		key = function(base)
			return base.name
		end,
		format_item = function(base)
			return base.name
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_branches(state.repo, { search = query }, finish)
			end, function(result, err)
				local matches = result
					and vim.tbl_filter(function(candidate)
						return candidate.name ~= branch.name
					end, result)
				done(matches, err)
			end)
		end,
		on_select = function(base)
			if not base or state.closed then
				return
			end

			state.statusline:notify("loading", "Preparing branch diff...")
			state.requests.run(function(done)
				return checkout.fetch_commits(root, state.remote, { base, branch }, done)
			end, function(ok, err)
				state.statusline:clear_notice()
				if not ok then
					notify.error(err or "Failed to fetch branch commits")
					return
				end

				diff.open_range({ root = root, base = base.hash, head = branch.hash }, function(open_err)
					if open_err then
						notify.error(open_err)
					end
				end)
			end)
		end,
	})
end

---@param state RepositoryBranches
local function toggle_history(state)
	local selection = current(state)
	if not selection or selection.commit or state.busy then
		return
	end

	if state.expanded == selection.branch.name then
		clear_commits(state)
		render(state)
		return
	end

	load_history(state, selection.branch)
	for row, entry in pairs(state.line_map) do
		if entry.branch.name == selection.branch.name and not entry.commit then
			vim.api.nvim_win_set_cursor(state.win, { row, 0 })
			break
		end
	end
end

---@param state RepositoryBranches
---@param branch AtlasRepositoryBranch
local function checkout_branch(state, branch)
	if state.busy then
		return
	end

	local root = local_root(state, "check out branches")
	if not root then
		return
	end

	state.busy = true
	state.statusline:notify("loading", "Checking out " .. branch.name .. "...")
	state.requests.run(function(done)
		return checkout.checkout_branch(root, state.remote, branch.name, done)
	end, function(ok, err)
		state.busy = false
		state.statusline:clear_notice()
		if not ok then
			notify.error(err or "Failed to check out branch")
			return
		end

		notify.success("Checked out " .. branch.name)
	end)
end

---@param state RepositoryBranches
local function delete(state)
	local selection = current(state)
	if not selection or selection.commit or state.busy then
		return
	end

	local branch = selection.branch
	if branch.name == state.repo.default_branch or branch.protected then
		notify.warn("Default and protected branches cannot be deleted")
		return
	end

	local repository = state.repository
	if not repository.delete_branch then
		return
	end

	vim.ui.input({
		prompt = string.format("Delete remote branch '%s' from '%s'? [y/N]: ", branch.name, state.repo.full_name),
	}, function(answer)
		local confirmed = answer and vim.trim(answer):lower()
		if (confirmed ~= "y" and confirmed ~= "yes") or state.closed or state.busy then
			return
		end

		state.busy = true
		state.statusline:notify("loading", "Deleting branch...")
		state.requests.run(function(done)
			return repository.delete_branch(state.repo, branch, done)
		end, function(ok, err)
			state.busy = false
			state.statusline:clear_notice()
			if not ok then
				notify.error(err or "Failed to delete branch")
				return
			end

			notify.success("Deleted branch " .. branch.name)
			load(state)
		end)
	end)
end

---@param state RepositoryBranches
local function open_actions(state)
	local selection = current(state)
	if not selection or state.busy then
		return
	end

	local items = {
		{
			label = "Open builds",
			run = function()
				open_pipeline(state, selection.branch)
			end,
		},
	}
	if state.root and not selection.commit then
		table.insert(items, {
			label = "Checkout branch",
			run = function()
				checkout_branch(state, selection.branch)
			end,
		})
	end

	picker.select({
		title = "Branch actions",
		items = items,
		format_item = function(item)
			return item.label
		end,
		on_select = function(item)
			if item and not state.closed then
				item.run()
			end
		end,
	})
end

---@param state RepositoryBranches
local function checkout_selection(state)
	local selection = current(state)
	if selection and not selection.commit then
		checkout_branch(state, selection.branch)
	end
end

---@param state RepositoryBranches
local function next_page(state)
	if state.branches ~= "loading" and state.next_cursor then
		load(state, state.page + 1)
	end
end

---@param state RepositoryBranches
local function previous_page(state)
	if state.branches ~= "loading" and state.page > 1 then
		load(state, state.page - 1)
	end
end

---@param state RepositoryBranches
local function show_details(state)
	info.toggle({
		source_win = state.win,
		content = function(line)
			local selection = state.line_map[line]
			if selection then
				return renderer.preview(selection.branch, selection.commit)
			end
		end,
	})
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryBranches
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		provider = opts.provider,
		repository = assert(opts.provider.capabilities.repository),
		branches = "loading",
		page = 1,
		cursors = {},
		root_request = requests.new(),
		root_loading = true,
		busy = false,
		closed = false,
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		keymaps = {},
	}

	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	vim.wo[state.win].cursorline = true
	keymaps.setup(state, {
		checkout = checkout_selection,
		delete = delete,
		load = load,
		next_page = next_page,
		open_actions = open_actions,
		open_diff = open_diff,
		previous_page = previous_page,
		search = search,
		show_details = show_details,
		toggle_history = toggle_history,
	})
	load(state)
	state.root_request.run(function(done)
		return checkout.resolve_repo_root(opts.repo.full_name, opts.repo.html_url, done)
	end, function(root, err, remote)
		if state.closed or not utils.window.has_buffer(state.win, state.buf) then
			return
		end

		state.root = root
		state.remote = remote
		state.root_error = err
		state.root_loading = false
		render(state)
	end)
end

---@param buf integer
function M.render(buf)
	local state = states[buf]
	if state then
		render(state)
	end
end

---@param buf integer
function M.close(buf)
	local state = states[buf]
	if not state then
		return
	end

	states[buf] = nil
	state.closed = true
	info.close(state.win)
	state.root_request.cancel()
	clear_commits(state)
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	for group, items in pairs(state.keymaps) do
		help.remove(group, items, { buffer = state.sidebar_buf })
	end
end

return M
