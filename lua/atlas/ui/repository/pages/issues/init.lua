local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local detail = require("atlas.issues.ui.detail")
local providers = require("atlas.providers")
local github_search = require("atlas.providers.github.completion.search")
local gitlab_query = require("atlas.providers.gitlab.query")
local gitlab_search = require("atlas.providers.gitlab.completion.search")
local spinner = require("atlas.ui.components.spinner")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.ui.repository.pages.issues.keymaps")
local renderer = require("atlas.ui.repository.pages.issues.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryIssues
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field issue_provider IssuesProvider|nil
---@field statusline AtlasStatusline
---@field issues Issue[]|string
---@field view IssuesViewConfig|nil
---@field query string|nil
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field total_pages integer|nil
---@field line_map table<integer, Issue>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field keymaps table<string, AtlasHelpKeyItem[]>

local M = { key = "issues", label = "Issues", icon = icons.get("issue") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.issues")
---@type table<integer, RepositoryIssues>
local states = {}

---@param state RepositoryIssues
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryIssues
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local issues = state.issues
	if type(issues) == "string" then
		local message = issues == "loading" and state.spinner:text("Loading issues...") or issues
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = issues == "loading" and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	if #issues == 0 then
		utils.buffer.center_message(state.buf, state.win, "No issues found.", lines)
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

---@param state RepositoryIssues
---@return IssuesViewConfig|nil
local function repository_view(state)
	if state.provider.id == "github" then
		return {
			name = "Issues",
			layout = "compact",
			search = string.format("repo:%s is:open sort:created-desc", state.repo.full_name),
		}
	elseif state.provider.id == "gitlab" then
		return {
			name = "Issues",
			layout = "compact",
			project = state.repo.full_name,
			scope = "all",
			state = "opened",
			order_by = "created_at",
			sort = "desc",
		}
	elseif state.provider.id == "azure" then
		return {
			name = "Issues",
			layout = "compact",
			project = state.repo.full_name:match("^([^/]+)/"),
			search = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
				.. " ORDER BY [System.CreatedDate] DESC",
		}
	end
end

---@param state RepositoryIssues
---@param force_refresh boolean|nil
local function load(state, force_refresh)
	state.requests.cancel()
	state.requests = requests.new()
	state.spinner:stop()
	state.statusline:clear_notice()
	state.next_cursor = nil
	local provider, view = state.issue_provider, state.view
	if not provider or not view then
		state.issues = "Issues are not available for this provider"
		render(state)
		return
	end

	state.issues = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading issues...")
	render(state)
	state.requests.run(function(done)
		return provider.capabilities.core.fetch_issues(view, {
			force_refresh = force_refresh == true,
			pagelen = 50,
			cursor = state.cursors[state.page],
		}, done)
	end, function(result, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		if err or not result then
			state.issues = err or "Unable to load issues"
			render(state)
			return
		end

		state.issues = result.items
		state.query = result.query
		state.next_cursor = result.next_cursor
		state.total_pages = result.total_pages
		render(state)
		if utils.window.valid(state.win) then
			for row = 1, vim.api.nvim_buf_line_count(state.buf) do
				if state.line_map[row] then
					vim.api.nvim_win_set_cursor(state.win, { row, 0 })
					break
				end
			end
		end
	end)
end

---@param state RepositoryIssues
local function edit_query(state)
	local view = state.view
	if not view or not state.query then
		return
	end

	local function apply()
		if states[state.buf] == state then
			state.page, state.cursors = 1, {}
			load(state)
		end
	end

	if state.provider.id == "github" then
		---@cast view AtlasGitHubIssuesViewConfig
		github_search.edit(state.query .. " ", function(query)
			view.search = query
			apply()
		end)
	elseif state.provider.id == "gitlab" then
		---@cast view AtlasGitLabIssuesViewConfig
		gitlab_search.edit("issues", state.query, function(query)
			local ok, err = gitlab_query.apply_issue(view, query)
			if not ok then
				notify.warn(err)
				return
			end

			apply()
		end)
	elseif state.provider.id == "azure" then
		---@cast view AtlasAzureIssuesViewConfig
		vim.ui.input({ prompt = "WIQL: ", default = state.query }, function(input)
			if input == nil or vim.trim(input) == "" then
				return
			end

			view.search = input
			apply()
		end)
	end
end

---@param state RepositoryIssues
local function toggle_state(state)
	local view = state.view
	if not view then
		return
	end

	if state.provider.id == "github" then
		---@cast view AtlasGitHubIssuesViewConfig
		local search = view.search
		if search:find("is:closed", 1, true) then
			search = search:gsub("is:closed", "is:open")
		elseif search:find("is:open", 1, true) then
			search = search:gsub("is:open", "is:closed")
		else
			search = search .. " is:closed"
		end

		view.search = search
	elseif state.provider.id == "gitlab" then
		---@cast view AtlasGitLabIssuesViewConfig
		view.state = view.state == "closed" and "opened" or "closed"
	else
		notify.info("Filter work item states in the WIQL query")
		return
	end

	state.page, state.cursors = 1, {}
	load(state)
end

---@param state RepositoryIssues
local function open_panel(state)
	local issue = current(state)
	if not issue then
		return
	end

	if state.issue_provider then
		detail.open(issue, { provider = state.issue_provider })
	else
		notify.warn("Issue details are not available for this provider")
	end
end

---@param state RepositoryIssues
local function refresh(state)
	state.page, state.cursors = 1, {}
	load(state, true)
end

---@param state RepositoryIssues
local function next_page(state)
	if state.issues ~= "loading" and state.next_cursor then
		state.page = state.page + 1
		state.cursors[state.page] = state.next_cursor
		load(state)
	end
end

---@param state RepositoryIssues
local function previous_page(state)
	if state.issues ~= "loading" and state.page > 1 then
		state.page = state.page - 1
		load(state)
	end
end

---@param state RepositoryIssues
local function open_in_browser(state)
	local issue = current(state)
	if issue and issue.url and issue.url ~= "" then
		vim.ui.open(issue.url)
	end
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	local issue_provider = providers.load(opts.provider.id, "issues")
	---@cast issue_provider IssuesProvider|nil
	---@type RepositoryIssues
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		provider = opts.provider,
		issue_provider = issue_provider,
		statusline = opts.statusline,
		issues = "loading",
		page = 1,
		cursors = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		keymaps = {},
	}

	state.view = repository_view(state)
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
		open_in_browser = open_in_browser,
		open_panel = open_panel,
		previous_page = previous_page,
		refresh = refresh,
		toggle_state = toggle_state,
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
