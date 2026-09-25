local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local diff = require("atlas.pulls.diff")
local pipelines = require("atlas.pulls.pipelines")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local info = require("atlas.ui.popups.info")
local history = require("atlas.ui.repository.pages.branches.git")
local keymaps = require("atlas.ui.repository.pages.branches.keymaps")
local renderer = require("atlas.ui.repository.pages.branches.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryBranches
---@field buf integer
---@field win integer
---@field navigation_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field branches AtlasRepositoryBranches|"loading"|string
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field root string|nil
---@field expanded string|nil
---@field commits RepositoryBranchCommit[]|"loading"|string|nil
---@field commit_request AtlasRequestScope|nil
---@field line_map table<integer, RepositoryBranchSelection>
---@field deleting string|nil
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field group integer

---@class RepositoryBranchSelection
---@field branch AtlasRepositoryBranch
---@field commit RepositoryBranchCommit|nil

---@type table<integer, RepositoryBranches>
local states = {}

local M = {
	key = "branches",
	label = "Branches",
	icon = icons.pulls("branch"),
}
local namespace = vim.api.nvim_create_namespace("atlas.repository.branches")

---@param state RepositoryBranches
---@return RepositoryBranchSelection|nil
local function selection_at_cursor(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryBranches
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(state.win)
	local selection = state.line_map[cursor[1]]
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
	elseif #branches.entries == 0 then
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

	local lines, line_map, spans = renderer.render(state, vim.api.nvim_win_get_width(state.win))
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
	for row, entry in pairs(line_map) do
		if selection and entry.branch.name == selection.branch.name then
			local same_commit = selection.commit and entry.commit and selection.commit.hash == entry.commit.hash
			if same_commit or (not selection.commit and not entry.commit) then
				vim.api.nvim_win_set_cursor(state.win, { row, cursor[2] })
				break
			end
		end
	end
end

---@param state RepositoryBranches
local function clear_commits(state)
	if state.commit_request then
		state.commit_request.cancel()
		state.commit_request = nil
	end
	state.expanded = nil
	state.commits = nil
	if not state.deleting then
		state.statusline:clear_notice()
	end
end

---@param state RepositoryBranches
---@param branch AtlasRepositoryBranch
local function load_history(state, branch)
	if not state.root then
		notify.warn("Configure this repository under pulls.repo_config.paths to browse its commits")
		return
	end
	clear_commits(state)
	state.expanded = branch.name
	state.commits = "loading"
	state.statusline:notify("loading", "Loading commits...")
	render(state)
	state.commit_request = history.load(state.root, branch, { repo_url = state.repo.html_url }, function(result, err)
		if not state.deleting then
			state.statusline:clear_notice()
		end
		state.commits = result or err or "Failed to load commits"
		render(state)
	end)
end

---@param state RepositoryBranches
---@param page integer|nil
local function load(state, page)
	if state.deleting then
		return
	end
	local repository = state.provider.capabilities.repository
	if not repository then
		state.branches = "Branches are not available for this provider"
		render(state)
		return
	end
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
			for _, branch in ipairs(branches.entries) do
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
	local repository = state.provider.capabilities.repository
	if not repository or state.deleting then
		return
	end
	local branches = state.branches
	picker.search({
		title = "Branches",
		initial_items = type(branches) == "table" and branches.entries or {},
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
			end, function(result, err)
				done(result and result.entries, err)
			end)
		end,
		on_select = function(branch)
			if not branch or states[state.buf] ~= state or not utils.window.valid(state.win) then
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
			state.branches = { entries = { branch } }
			state.spinner:stop()
			render(state)
			vim.api.nvim_set_current_win(state.win)
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end,
	})
end

---@param provider_id AtlasProviderId
---@param repo AtlasRepositoryDetails
---@param branch AtlasRepositoryBranch
local function open_pipeline(provider_id, repo, branch)
	local provider = providers.load(provider_id, "pulls")
	---@cast provider PullsProvider|nil
	if not provider or not pipelines.get(provider) then
		notify.warn("Pipelines are not available for this provider")
		return
	end
	pipelines.open({
		provider = provider.id,
		repo_full_name = repo.full_name or repo.name,
		target = branch.name,
	}, provider)
end

---@param state RepositoryBranches
local function open_diff(state)
	local selection = selection_at_cursor(state)
	if not selection then
		return
	end
	local root = state.root
	if not root then
		notify.warn("Configure this repository under pulls.repo_config.paths to open diffs")
		return
	end
	local commit = selection.commit
	if commit then
		if not commit.parent then
			notify.warn("This commit has no local parent to compare")
			return
		end
		diff.open_range({ root = root, base = commit.parent, head = commit.hash }, function(err)
			if err then
				notify.error(err)
			end
		end)
		return
	end

	local repository = state.provider.capabilities.repository
	if not repository then
		return
	end
	local branch = selection.branch
	local branches = state.branches --[[@as AtlasRepositoryBranches]]
	local bases = {}
	for _, candidate in ipairs(branches.entries) do
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
					end, result.entries)
				done(matches, err)
			end)
		end,
		on_select = function(base)
			if not base or states[state.buf] ~= state then
				return
			end
			state.statusline:notify("loading", "Preparing branch diff...")
			state.requests.run(function(done)
				return history.fetch(root, { base, branch }, { repo_url = state.repo.html_url }, done)
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
local function select_current(state)
	local selection = selection_at_cursor(state)
	if not selection or selection.commit then
		return
	end
	if state.expanded == selection.branch.name then
		clear_commits(state)
		render(state)
	else
		load_history(state, selection.branch)
	end
end

---@param state RepositoryBranches
local function delete_branch(state)
	local selection = selection_at_cursor(state)
	if not selection or selection.commit or state.deleting then
		return
	end
	local branch = selection.branch
	if branch.name == state.repo.default_branch or branch.protected then
		notify.warn("Default and protected branches cannot be deleted")
		return
	end
	local repository = state.provider.capabilities.repository
	if not repository or not repository.delete_branch then
		return
	end
	vim.ui.input({
		prompt = string.format(
			"Delete remote branch '%s' from '%s'? [y/N]: ",
			branch.name,
			state.repo.full_name or state.repo.name
		),
	}, function(answer)
		local confirmed = answer and vim.trim(answer):lower()
		if (confirmed ~= "y" and confirmed ~= "yes") or states[state.buf] ~= state or state.deleting then
			return
		end
		state.deleting = branch.name
		state.statusline:notify("loading", "Deleting branch...")
		state.requests.run(function(done)
			return repository.delete_branch(state.repo, branch, done)
		end, function(ok, err)
			state.deleting = nil
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

---@param opts { buf: integer, win: integer, navigation_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	local repository = opts.provider.capabilities.repository
	---@type RepositoryBranches
	local state = {
		buf = opts.buf,
		win = opts.win,
		navigation_buf = opts.navigation_buf,
		repo = opts.repo,
		provider = opts.provider,
		branches = "loading",
		page = 1,
		cursors = {},
		root = history.resolve(opts.repo),
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		group = vim.api.nvim_create_augroup("AtlasRepositoryBranches" .. opts.buf, { clear = true }),
	}
	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end
	vim.wo[state.win].cursorline = true
	keymaps.setup(state.buf, state.navigation_buf, {
		search = function()
			search(state)
		end,
		refresh = function()
			load(state)
		end,
		next_page = function()
			if state.branches ~= "loading" and state.next_cursor then
				load(state, state.page + 1)
			end
		end,
		previous_page = function()
			if state.branches ~= "loading" and state.page > 1 then
				load(state, state.page - 1)
			end
		end,
		select = function()
			select_current(state)
		end,
		details = function()
			info.toggle({
				source_win = state.win,
				content = function(line)
					local selection = state.line_map[line]
					if selection then
						return renderer.preview(selection.branch, selection.commit)
					end
				end,
			})
		end,
		diff = function()
			open_diff(state)
		end,
		actions = function()
			local selection = selection_at_cursor(state)
			if not selection then
				return
			end
			picker.select({
				title = "Branch actions",
				items = { "Open builds" },
				on_select = function(item)
					if item and states[state.buf] == state then
						open_pipeline(state.provider.id, state.repo, selection.branch)
					end
				end,
			})
		end,
		delete = repository and repository.delete_branch and function()
			delete_branch(state)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function(event)
			if event.event == "VimResized" or vim.tbl_contains(vim.v.event.windows, state.win) then
				render(state)
			end
		end,
	})
	load(state)
end

---@param buf integer
function M.close(buf)
	local state = states[buf]
	info.close(state.win)
	states[buf] = nil
	clear_commits(state)
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	keymaps.clear(state.buf)
	keymaps.clear(state.navigation_buf)
	if utils.window.valid(state.win) then
		vim.wo[state.win].cursorline = false
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
