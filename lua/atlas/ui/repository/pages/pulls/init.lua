local opener = require("atlas.commands.open")
local diff = require("atlas.pulls.diff")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local azure_query = require("atlas.providers.azure.query")
local bitbucket_search = require("atlas.providers.bitbucket.completion.search")
local github_search = require("atlas.providers.github.completion.search")
local gitlab_query = require("atlas.providers.gitlab.query")
local gitlab_search = require("atlas.providers.gitlab.completion.search")
local spinner = require("atlas.ui.components.spinner")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.ui.repository.pages.pulls.keymaps")
local renderer = require("atlas.ui.repository.pages.pulls.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryPulls
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field provider PullsProvider|nil
---@field view AtlasPullsViewConfig|nil
---@field query string|nil
---@field statusline AtlasStatusline
---@field pulls PullRequest[]|string
---@field page integer
---@field cursors table<integer, table<string, string>>
---@field next_cursor table<string, string>|nil
---@field total_pages integer|nil
---@field line_map table<integer, PullRequest>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field keymaps table<string, AtlasHelpKeyItem[]>

local M = { key = "pulls", label = "Pull Requests", icon = icons.get("pr") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.pulls")
---@type PullsStateFilter[]
local filters = { "open", "merged", "declined" }
---@type table<integer, RepositoryPulls>
local states = {}

---@param state RepositoryPulls
---@return PullRequest|nil
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryPulls
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local pulls = state.pulls
	if type(pulls) == "string" then
		local message = pulls == "loading" and state.spinner:text("Loading pull requests...") or pulls
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = pulls == "loading" and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	if #pulls == 0 then
		utils.buffer.center_message(state.buf, state.win, "No pull requests found.", lines)
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

---@param state RepositoryPulls
---@param force_refresh boolean|nil
local function load(state, force_refresh)
	state.requests.cancel()
	state.requests = requests.new()
	state.spinner:stop()
	state.statusline:clear_notice()
	local provider, view = state.provider, state.view
	if not provider or not view then
		state.pulls = "Pull requests are not available for this repository"
		render(state)
		return
	end

	state.pulls = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading pull requests...")
	render(state)
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, {
			force_refresh = force_refresh == true,
			pagelen = 50,
			cursor = state.cursors[state.page],
		}, done)
	end, function(page, errors)
		state.spinner:stop()
		state.statusline:clear_notice()
		state.query = page.query
		if errors and #errors > 0 then
			state.pulls = table.concat(errors, "\n")
			state.next_cursor = nil
		else
			state.pulls = page.items
			state.next_cursor = page.next_cursor
			state.total_pages = page.total_pages
		end

		render(state)
		for row = 1, vim.api.nvim_buf_line_count(state.buf) do
			if state.line_map[row] then
				vim.api.nvim_win_set_cursor(state.win, { row, 0 })
				break
			end
		end
	end)
end

---@param state RepositoryPulls
local function reload(state)
	if states[state.buf] == state then
		state.page, state.cursors, state.next_cursor = 1, {}, nil
		load(state)
	end
end

---@param state RepositoryPulls
local function edit_query(state)
	local provider, view = state.provider, state.view
	if not provider or not view or not state.query then
		return
	end

	if provider.id == "github" then
		---@cast view AtlasGitHubViewConfig
		github_search.edit(state.query .. " ", function(query)
			view.search = query
			view._states = nil
			reload(state)
		end)
	elseif provider.id == "gitlab" then
		---@cast view AtlasGitLabPullsViewConfig
		gitlab_search.edit("pulls", state.query, function(query)
			local ok, err = gitlab_query.apply(view, query)
			if not ok then
				notify.warn(err)
				return
			end

			reload(state)
		end)
	elseif provider.id == "bitbucket" then
		---@cast view AtlasBitbucketViewConfig
		bitbucket_search.edit({ name = "Search", search = state.query }, function(query)
			view.search = query
			view._states = nil
			reload(state)
		end)
	elseif provider.id == "azure" then
		---@cast view AtlasAzurePullsViewConfig
		vim.ui.input({ prompt = "Search: ", default = state.query }, function(input)
			if input == nil or vim.trim(input) == "" then
				return
			end

			local ok, err = azure_query.apply(view, input)
			if not ok then
				notify.warn(err)
				return
			end

			reload(state)
		end)
	end
end

---@param state RepositoryPulls
---@param status PullsStateFilter
local function toggle_filter(state, status)
	local provider, view = state.provider, state.view
	if not provider or not view then
		return
	end

	local _, active = provider.resolve_search(view)
	local selected = {}
	for _, value in ipairs(active) do
		selected[value] = true
	end

	if selected[status] and #active == 1 then
		notify.warn("At least one status filter must remain active")
		return
	end

	selected[status] = not selected[status]
	view._states = vim.tbl_filter(function(value)
		return selected[value]
	end, filters)
	reload(state)
end

---@param state RepositoryPulls
local function refresh(state)
	state.page, state.cursors, state.next_cursor = 1, {}, nil
	load(state, true)
end

---@param state RepositoryPulls
local function next_page(state)
	if state.pulls ~= "loading" and state.next_cursor then
		state.page = state.page + 1
		state.cursors[state.page] = state.next_cursor
		load(state)
	end
end

---@param state RepositoryPulls
local function previous_page(state)
	if state.pulls ~= "loading" and state.page > 1 then
		state.page = state.page - 1
		load(state)
	end
end

---@param state RepositoryPulls
local function open_diff(state)
	local pr = current(state)
	if pr then
		diff.open_pr(pr, function(err)
			if err then
				state.statusline:notify("error", err)
			end
		end)
	end
end

---@param state RepositoryPulls
local function open_panel(state)
	local pr = current(state)
	if pr then
		opener.open(pr.link.html)
	end
end

---@param state RepositoryPulls
local function open_in_browser(state)
	local pr = current(state)
	if pr then
		vim.ui.open(pr.link.html)
	end
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	local provider = providers.load(opts.provider.id, "pulls")
	---@cast provider PullsProvider|nil
	local target = providers.resolve(opts.repo.html_url or "")
	---@type RepositoryPulls
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		provider = provider,
		view = provider and target and provider.repository_view(target),
		statusline = opts.statusline,
		pulls = "loading",
		page = 1,
		cursors = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		keymaps = {},
	}

	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	vim.wo[state.win].cursorline = true
	vim.wo[state.win].wrap = false
	keymaps.setup(state, {
		edit_query = edit_query,
		next_page = next_page,
		open_diff = open_diff,
		open_in_browser = open_in_browser,
		open_panel = open_panel,
		previous_page = previous_page,
		refresh = refresh,
		toggle_filter = toggle_filter,
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
end

return M
