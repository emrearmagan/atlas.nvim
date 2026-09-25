local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local pipelines = require("atlas.pulls.pipelines")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local renderer = require("atlas.ui.repository.pages.builds.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryBuilds
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|nil
---@field backend PullsPipelineBackend|nil
---@field statusline AtlasStatusline
---@field branch string|nil
---@field runs PullsPipeline[]|string
---@field selected_id string|nil
---@field line_map table<integer, PullsPipeline>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field group integer
---@field keymaps table<integer, AtlasHelpKeyItem[]>

local M = { key = "builds", label = "Builds", icon = icons.pulls("pipeline") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.builds")
---@type table<integer, RepositoryBuilds>
local states = {}

---@param state RepositoryBuilds
---@return PullsPipeline|nil
local function current(state)
	if not utils.window.valid(state.win) then
		return nil
	end
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryBuilds
---@param selected_id string|nil
local function render(state, selected_id)
	if states[state.buf] ~= state or not utils.window.valid(state.win) or not utils.buffer.valid(state.buf) then
		return
	end
	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	if type(state.runs) == "string" then
		local message = state.runs == "loading" and state.spinner:text("Loading builds...") or state.runs
		---@cast message string
		utils.buffer.center_message(state.buf, state.win, message)
		return
	end
	if #state.runs ~= 0 then
		utils.buffer.center_message(
			state.buf,
			state.win,
			"No builds found for this branch.\nPress b to view another branch."
		)
		return
	end
	local lines, line_map, spans = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col or 0, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	vim.bo[state.buf].modifiable = false
	if selected_id then
		for row = 1, #lines do
			if line_map[row] and line_map[row].id == selected_id then
				vim.api.nvim_win_set_cursor(state.win, { row, 0 })
				return
			end
		end
	end
end

---@param state RepositoryBuilds
local function load(state)
	local selected = current(state)
	state.selected_id = selected and selected.id or state.selected_id
	state.requests.cancel()
	state.requests = requests.new()
	state.spinner:stop()
	state.statusline:clear_notice()
	if not state.backend or not state.backend.fetch_history then
		state.runs = "Build history is not available for the configured CI backend"
		render(state)
		return
	end
	if not state.branch or state.branch == "" then
		state.runs = "No default branch available. Press b to choose a branch."
		render(state)
		return
	end
	state.runs = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading builds...")
	render(state)
	state.requests.run(function(done)
		return state.backend.fetch_history({
			provider = state.provider.id,
			repo_full_name = state.repo.full_name or state.repo.name,
			target = state.branch,
		}, done)
	end, function(runs, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		state.runs = runs or err or "Unable to load builds"
		local selected_run
		if runs then
			local selected_id = state.selected_id
			selected_run = runs[1]
			for _, run in ipairs(runs) do
				if run.id == selected_id then
					selected_run = run
					break
				end
			end
			state.selected_id = selected_run and selected_run.id
		end
		render(state, state.selected_id)
	end)
end

---@param state RepositoryBuilds
local function change_branch(state)
	if not state.backend or not state.backend.fetch_history or state.runs == "loading" then
		return
	end
	local repository = state.provider.capabilities.repository
	if not repository or not repository.fetch_branches then
		notify.info("Branches are not available for this repository")
		return
	end
	picker.search({
		title = "Builds for branch",
		fetch_on_open = true,
		key = function(branch)
			return branch.name
		end,
		format_item = function(branch)
			return branch.name .. (branch.name == state.repo.default_branch and "  (default)" or "")
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_branches(state.repo, { search = query }, finish)
			end, function(result, err)
				done(result and result.entries or nil, err)
			end)
		end,
		on_select = function(branch)
			if not branch or states[state.buf] ~= state then
				return
			end
			state.branch = branch.name
			state.selected_id = nil
			state.line_map = {}
			load(state)
		end,
	})
end

---@param state RepositoryBuilds
---@param buf integer
---@param actions table[]
local function register(state, buf, actions)
	local items = {}
	for _, action in ipairs(actions) do
		if action[1] and #action[1] > 0 then
			items[#items + 1] = {
				key = action[1],
				desc = action[2],
				callback = action[3],
				opts = { silent = true, nowait = true },
			}
		end
	end
	state.keymaps[buf] = items
	help.register("Builds", items, { buffer = buf })
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	local provider = providers.load(opts.provider.id, "pulls")
	---@cast provider PullsProvider|nil
	---@type RepositoryBuilds
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		provider = provider,
		backend = provider and pipelines.get(provider),
		statusline = opts.statusline,
		branch = opts.repo.default_branch,
		runs = "loading",
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryBuilds" .. opts.buf, { clear = true }),
		keymaps = {},
	}
	states[state.buf] = state
	vim.wo[state.win].cursorline = true
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end
	local actions = {
		{
			resolver.resolve("ui.refresh"),
			"Refresh builds",
			function()
				load(state)
			end,
		},
		{
			"b",
			"Change build branch",
			function()
				change_branch(state)
			end,
		},
	}
	register(state, state.sidebar_buf, actions)
	vim.list_extend(actions, {
		{
			resolver.resolve("ui.select"),
			"Open build and logs",
			function()
				local run = current(state)
				if run then
					pipelines.open({
						provider = state.provider.id,
						repo_full_name = state.repo.full_name or state.repo.name,
						target = run,
					}, state.provider)
				end
			end,
		},
		{
			resolver.resolve("ui.open_in_browser"),
			"Open build in browser",
			function()
				local run = current(state)
				if run and run.url then
					vim.ui.open(run.url)
				elseif run then
					notify.info("This build has no browser URL")
				end
			end,
		},
	})
	register(state, state.buf, actions)
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function()
			local run = current(state)
			render(state, run and run.id)
		end,
	})
	load(state)
end

---@param buf integer
function M.close(buf)
	local state = states[buf]
	if not state then
		return
	end
	states[buf] = nil
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	for buffer, items in pairs(state.keymaps) do
		help.remove("Builds", items, { buffer = buffer })
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
