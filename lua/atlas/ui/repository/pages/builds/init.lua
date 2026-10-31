local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local pipelines = require("atlas.pulls.pipelines")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.ui.repository.pages.builds.keymaps")
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
---@field line_map table<integer, PullsPipeline>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field keymaps table<string, AtlasHelpKeyItem[]>

local M = { key = "builds", label = "Builds", icon = icons.get("pipeline") }
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
local function render(state)
	if states[state.buf] ~= state or not utils.window.valid(state.win) or not utils.buffer.valid(state.buf) then
		return
	end

	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local runs = state.runs
	if type(runs) == "string" then
		local message = runs == "loading" and state.spinner:text("Loading builds...") or runs
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = runs == "loading" and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	if #runs == 0 then
		utils.buffer.center_message(state.buf, state.win, "No builds found", lines)
	else
		vim.bo[state.buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
		vim.bo[state.buf].modifiable = false
	end

	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col or 0, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param state RepositoryBuilds
local function load(state)
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
		state.runs = "No default branch available"
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
			repo_full_name = state.repo.full_name,
			target = state.branch,
		}, done)
	end, function(runs, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		state.runs = runs or err or "Unable to load builds"
		render(state)
		if runs and #runs > 0 and utils.window.valid(state.win) then
			vim.api.nvim_win_set_cursor(state.win, { 3, 0 })
		end
	end)
end

---@param state RepositoryBuilds
local function change_branch(state)
	if not state.backend or not state.backend.fetch_history or state.runs == "loading" then
		return
	end

	local repository = state.provider.capabilities.repository
	if not repository then
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
			end, done)
		end,
		on_select = function(branch)
			if not branch or states[state.buf] ~= state then
				return
			end

			state.branch = branch.name
			load(state)
		end,
	})
end

---@param state RepositoryBuilds
local function open_build(state)
	local run = current(state)
	if run then
		pipelines.open({
			provider = state.provider.id,
			repo_full_name = state.repo.full_name,
			target = run,
		}, state.provider)
	end
end

---@param state RepositoryBuilds
local function open_in_browser(state)
	local run = current(state)
	if run and run.url then
		vim.ui.open(run.url)
	elseif run then
		notify.info("This build has no browser URL")
	end
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
		keymaps = {},
	}

	states[state.buf] = state
	vim.wo[state.win].cursorline = true
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	keymaps.setup(
		state,
		{ change_branch = change_branch, load = load, open_build = open_build, open_in_browser = open_in_browser }
	)
	load(state)
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
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	for group, items in pairs(state.keymaps) do
		help.remove(group, items, { buffer = state.sidebar_buf })
	end
end

return M
