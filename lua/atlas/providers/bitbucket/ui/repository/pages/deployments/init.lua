local requests = require("atlas.core.requests")
local deployments = require("atlas.providers.bitbucket.deployments")
local actions = require("atlas.providers.bitbucket.ui.repository.pages.deployments.actions")
local keymaps = require("atlas.providers.bitbucket.ui.repository.pages.deployments.keymaps")
local renderer = require("atlas.providers.bitbucket.ui.repository.pages.deployments.renderer")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryDeployments
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field environments BitbucketDeploymentEnvironment[]|string
---@field expanded table<string, boolean>
---@field line_map table<integer, { environment: BitbucketDeploymentEnvironment, deployment?: BitbucketDeployment }>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field keymaps table<string, AtlasHelpKeyItem[]>

local M = { key = "deployments", label = "Deployments", icon = icons.get("deployment") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.deployments")
---@type table<integer, RepositoryDeployments>
local states = {}

---@param buf integer
---@param lines string[]
---@param spans AtlasUIHighlight[]
local function write(buf, lines, spans)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	vim.bo[buf].modifiable = false
end

---@param state RepositoryDeployments
local function render(state)
	if states[state.buf] ~= state or not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end
	state.line_map = {}
	local environments = state.environments
	local message, hl
	if environments == "loading" then
		message, hl = state.spinner:text("Loading deployments..."), "Normal"
	elseif type(environments) == "string" then
		message, hl = environments, "AtlasLogError"
	elseif #environments == 0 then
		message, hl = "No environments found.", "AtlasTextMuted"
	end
	if message then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = hl,
		})
		return
	end
	---@cast environments BitbucketDeploymentEnvironment[]
	local lines, line_map, spans = renderer.render(environments, vim.api.nvim_win_get_width(state.win), state.expanded)
	state.line_map = line_map
	write(state.buf, lines, spans)
end

---@param state RepositoryDeployments
local function load(state)
	state.requests.cancel()
	state.requests = requests.new()
	state.environments = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading deployments...")
	render(state)
	state.requests.all({
		environments = function(done)
			return deployments.fetch_environments(state.repo, done)
		end,
		deployments = function(done)
			return deployments.fetch(state.repo, done)
		end,
	}, function(results, errors)
		state.spinner:stop()
		state.statusline:clear_notice()
		local err = errors.environments or errors.deployments
		if err then
			state.environments = err
		else
			---@type BitbucketDeploymentEnvironment[]
			local environments = results.environments
			local by_id = {}
			for _, environment in ipairs(environments) do
				by_id[environment.id] = environment
			end
			for _, deployment in ipairs(results.deployments) do
				local environment = by_id[deployment.environment_id]
				if environment then
					environment.deployments[#environment.deployments + 1] = deployment
				end
			end
			state.environments = environments
		end
		render(state)
		if utils.window.valid(state.win) then
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end
	end)
end

---@param state RepositoryDeployments
---@param row { environment: BitbucketDeploymentEnvironment, deployment?: BitbucketDeployment }|nil
---@param action BitbucketDeploymentAction|nil
local function open_actions(state, row, action)
	if not row then
		return
	end
	local ctx = {
		repo = state.repo,
		deployment = row.deployment or row.environment.deployments[1],
	}
	local function run(selected)
		if not selected or states[state.buf] ~= state then
			return
		end
		selected.run(ctx)
	end
	if action then
		if action.is_available(ctx) then
			run(action)
		end
		return
	end
	local available = {}
	for _, item in ipairs(actions.items) do
		if item.is_available(ctx) then
			available[#available + 1] = item
		end
	end
	picker.select({
		title = "Actions: " .. row.environment.name,
		items = available,
		format_item = function(item)
			local label = type(item.label) == "function" and item.label(ctx) or item.label
			return item.icon .. "  " .. label
		end,
		on_select = run,
	})
end

---@param state RepositoryDeployments
---@return { environment: BitbucketDeploymentEnvironment, deployment?: BitbucketDeployment }|nil
local function current(state)
	if not utils.window.valid(state.win) then
		return nil
	end
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryDeployments
local function toggle_history(state)
	local row = current(state)
	if not row or #row.environment.deployments <= 3 then
		return
	end
	local id = row.environment.id
	state.expanded[id] = not state.expanded[id]
	render(state)
end

---@param state RepositoryDeployments
local function open_build(state)
	open_actions(state, current(state), actions.open_build)
end

---@param state RepositoryDeployments
local function show_actions(state)
	open_actions(state, current(state))
end

---@param state RepositoryDeployments
local function open_in_browser(state)
	open_actions(state, current(state), actions.open_in_browser)
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryDeployments
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		environments = "loading",
		expanded = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		keymaps = {},
	}
	states[state.buf] = state
	vim.wo[state.win].cursorline = true
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	keymaps.setup(state, {
		load = load,
		open_build = open_build,
		open_in_browser = open_in_browser,
		show_actions = show_actions,
		toggle_history = toggle_history,
	})
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
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
