local resolver = require("atlas.core.keymaps")
local requests = require("atlas.core.requests")
local deployments = require("atlas.providers.bitbucket.deployments")
local actions = require("atlas.providers.bitbucket.ui.repository.deployments.actions")
local renderer = require("atlas.providers.bitbucket.ui.repository.deployments.renderer")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryDeployments
---@field buf integer
---@field win integer
---@field repo AtlasRepositoryDetails
---@field environments BitbucketDeploymentEnvironment[]|string
---@field expanded table<string, boolean>
---@field line_map table<integer, { environment: BitbucketDeploymentEnvironment, deployment?: BitbucketDeployment }>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field group integer
---@field keymaps table<integer, AtlasHelpKeyItem[]>

local M = { key = "deployments", label = "Deployments", icon = icons.general("deployment") }
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
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
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
		format_item = icons.format_action,
		on_select = run,
	})
end

---@param state RepositoryDeployments
---@param buf integer
---@param mappings table[]
local function register(state, buf, mappings)
	local items = {}
	for _, action in ipairs(mappings) do
		local keys = action[1]
		if keys and #keys > 0 then
			items[#items + 1] = {
				key = keys,
				desc = action[2],
				callback = action[3],
				opts = { silent = true, nowait = true },
			}
		end
	end
	state.keymaps[buf] = items
	help.register("Deployments", items, { buffer = buf })
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryDeployments
	local state = {
		buf = opts.buf,
		win = opts.win,
		repo = opts.repo,
		environments = "loading",
		expanded = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		group = vim.api.nvim_create_augroup("AtlasRepositoryDeployments" .. opts.buf, { clear = true }),
		keymaps = {},
	}
	states[state.buf] = state
	vim.wo[state.win].cursorline = true
	state.spinner.on_tick = function()
		render(state)
	end
	local mappings = {
		{
			resolver.resolve("ui.refresh"),
			"Refresh deployments",
			function()
				load(state)
			end,
		},
	}
	register(state, opts.sidebar_buf, mappings)
	vim.list_extend(mappings, {
		{
			resolver.resolve("ui.toggle_fold"),
			"Toggle environment history",
			function()
				local row = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
				if not row or #row.environment.deployments <= 3 then
					return
				end
				local id = row.environment.id
				state.expanded[id] = not state.expanded[id]
				render(state)
			end,
		},
		{
			vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.show_details") or {}),
			"Open build",
			function()
				local row = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
				open_actions(state, row, actions.open_build)
			end,
		},
		{
			resolver.resolve("ui.open_actions"),
			"Deployment actions",
			function()
				local row = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
				open_actions(state, row)
			end,
		},
		{
			resolver.resolve("ui.open_in_browser"),
			"Open deployment in browser",
			function()
				local row = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
				open_actions(state, row, actions.open_in_browser)
			end,
		},
	})
	register(state, state.buf, mappings)
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function()
			render(state)
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
		help.remove("Deployments", items, { buffer = buffer })
	end
end

return M
