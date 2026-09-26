local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local issue_list = require("atlas.issues.ui.components.issue_list")
local detail = require("atlas.issues.ui.detail")
local providers = require("atlas.providers")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
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
---@field filter "open"|"closed"
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field total_pages integer|nil
---@field summary AtlasRepositoryIssueSummary|nil
---@field line_map table<integer, Issue>
---@field requests AtlasRequestScope
---@field summary_requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field group integer
---@field keymaps table<integer, AtlasHelpKeyItem[]>

local M = { key = "issues", label = "Issues", icon = icons.issues("issue") }
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
	local selected = current(state)
	local cursor = vim.api.nvim_win_get_cursor(state.win)
	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local issues = state.issues
	if type(issues) == "string" then
		local message = issues == "loading" and state.spinner:text("Loading " .. state.filter .. " issues...") or issues
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = issues == "loading" and "Normal" or "AtlasLogError",
		})
		return
	end
	local width = vim.api.nvim_win_get_width(state.win)
	local header, spans = " ", {}
	for _, filter in ipairs({ "open", "closed" }) do
		local label = filter:gsub("^%l", string.upper)
		if state.summary then
			label = string.format("%s (%d)", label, state.summary[filter])
		end
		spans[#spans + 1] = {
			line = 0,
			start_col = #header,
			end_col = #header + #label,
			hl_group = state.filter == filter and "Normal" or "AtlasTextMuted",
		}
		header = header .. label .. "  "
	end
	if state.page > 1 or state.next_cursor then
		local page = "Page " .. state.page .. (state.total_pages and ("/" .. state.total_pages) or "")
		spans[#spans + 1] = { line = 0, start_col = #header, end_col = #header + #page, hl_group = "AtlasTextMuted" }
		header = header .. page
	end
	local lines = { header }
	for index, item in ipairs(state.summary and state.summary.items or {}) do
		local label = (item.label .. ": "):gsub("%c", " ")
		local text = utils.truncate(label .. tostring(item.value):gsub("%c", " "), math.max(1, width - 2))
		if index == 1 or vim.api.nvim_strwidth(lines[#lines] .. text) > width then
			lines[#lines + 1] = " "
		end
		local col = #lines[#lines]
		lines[#lines] = lines[#lines] .. text .. "  "
		spans[#spans + 1] = {
			line = #lines - 1,
			start_col = col,
			end_col = col + math.min(#label, #text),
			hl_group = "AtlasTextMuted",
		}
		if #text > #label then
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = col + #label,
				end_col = col + #text,
				hl_group = "Normal",
			}
		end
	end
	lines[#lines + 1] = ""
	if #issues == 0 then
		utils.buffer.center_message(state.buf, state.win, "No " .. state.filter .. " issues found.", lines)
	else
		local table_lines, table_map, table_spans = issue_list.render_compact({
			width = width,
			provider_id = state.provider.id,
		}, issues)
		local offset = #lines
		utils.append_block(lines, spans, { lines = table_lines, highlights = table_spans })
		for row, node in pairs(table_map) do
			if node.kind == "issue" and node._issue then
				state.line_map[offset + row] = node._issue
			end
		end
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
	if #issues == 0 then
		return
	end
	for row = 1, #lines do
		local issue = state.line_map[row]
		if issue and selected and issue.key == selected.key then
			vim.api.nvim_win_set_cursor(state.win, { row, 0 })
			return
		end
	end
	vim.api.nvim_win_set_cursor(state.win, { math.min(cursor[1], #lines), 0 })
end

---@param state RepositoryIssues
---@param force_refresh boolean|nil
local function load(state, force_refresh)
	state.requests.cancel()
	state.requests = requests.new()
	state.spinner:stop()
	state.statusline:clear_notice()
	state.next_cursor = nil
	local fetch = state.issue_provider and state.issue_provider.capabilities.core.fetch_issues
	---@type IssuesViewConfig|nil
	local view
	if state.provider.id == "github" then
		view = {
			name = "Issues",
			layout = "compact",
			search = string.format("repo:%s is:%s sort:created-desc", state.repo.full_name, state.filter),
		}
	elseif state.provider.id == "gitlab" then
		view = {
			name = "Issues",
			layout = "compact",
			project = state.repo.full_name,
			scope = "all",
			state = state.filter == "open" and "opened" or "closed",
			order_by = "created_at",
			sort = "desc",
		}
	end
	if not fetch or not view then
		state.issues = "Issues are not available for this provider"
		render(state)
		return
	end
	local filter = state.filter
	state.issues = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading " .. filter .. " issues...")
	render(state)
	state.requests.run(function(done)
		return fetch(view, {
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
local function search(state)
	local issues = state.issues
	if type(issues) == "string" or #issues == 0 then
		return
	end
	picker.select({
		title = state.filter:gsub("^%l", string.upper) .. " issues on this page",
		items = issues,
		format_item = function(issue)
			return string.format(
				"%s  %s  ·  %s",
				issue.key:match("#%d+$") or issue.key,
				issue.title:gsub("%c", " "),
				issue.reporter and issue.reporter.name or "Unknown"
			)
		end,
		on_select = function(issue)
			if not issue or states[state.buf] ~= state or not utils.window.valid(state.win) then
				return
			end
			for row = 1, vim.api.nvim_buf_line_count(state.buf) do
				local entry = state.line_map[row]
				if entry and entry.key == issue.key then
					vim.api.nvim_set_current_win(state.win)
					vim.api.nvim_win_set_cursor(state.win, { row, 0 })
					return
				end
			end
		end,
	})
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
---@param buf integer
---@param actions table[]
local function register(state, buf, actions)
	local items = {}
	for _, action in ipairs(actions) do
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
	help.register("Issues", items, { buffer = buf })
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
		filter = "open",
		page = 1,
		cursors = {},
		line_map = {},
		requests = requests.new(),
		summary_requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryIssues" .. opts.buf, { clear = true }),
		keymaps = {},
	}
	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end
	vim.bo[state.buf].filetype = "atlas.repository"
	vim.wo[state.win].cursorline = true
	vim.wo[state.win].wrap = false
	local actions = {
		{
			resolver.resolve("ui.refresh"),
			"Refresh issues",
			function()
				state.page, state.cursors = 1, {}
				load(state, true)
			end,
		},
		{
			resolver.resolve("ui.search"),
			"Search this page",
			function()
				search(state)
			end,
		},
		{
			resolver.resolve("pulls.toggle_repo_issue_state"),
			"Toggle open/closed issues",
			function()
				state.filter = state.filter == "open" and "closed" or "open"
				state.page, state.cursors = 1, {}
				load(state)
			end,
		},
		{
			resolver.resolve("ui.next_page"),
			"Next issues",
			function()
				if state.issues == "loading" or not state.next_cursor then
					return
				end
				state.page = state.page + 1
				state.cursors[state.page] = state.next_cursor
				load(state)
			end,
		},
		{
			resolver.resolve("ui.previous_page"),
			"Previous issues",
			function()
				if state.issues ~= "loading" and state.page > 1 then
					state.page = state.page - 1
					load(state)
				end
			end,
		},
	}
	register(state, state.sidebar_buf, actions)
	local panel_keys = resolver.resolve("ui.select") or {}
	if not vim.tbl_contains(panel_keys, "p") then
		panel_keys[#panel_keys + 1] = "p"
	end
	vim.list_extend(actions, {
		{
			panel_keys,
			"Open issue panel",
			function()
				open_panel(state)
			end,
		},
		{
			resolver.resolve("ui.open_in_browser"),
			"Open issue in browser",
			function()
				local issue = current(state)
				if issue and issue.url and issue.url ~= "" then
					vim.ui.open(issue.url)
				end
			end,
		},
	})
	register(state, state.buf, actions)
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function(event)
			if event.event == "VimResized" or vim.tbl_contains(vim.v.event.windows, state.win) then
				render(state)
			end
		end,
	})
	load(state)
	local repository = state.provider.capabilities.repository
	local fetch_summary = repository and repository.fetch_issue_summary
	if fetch_summary then
		state.summary_requests.run(function(done)
			return fetch_summary(state.repo, done)
		end, function(summary)
			state.summary = summary
			render(state)
		end)
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
	state.summary_requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	for buffer, items in pairs(state.keymaps) do
		help.remove("Issues", items, { buffer = buffer })
	end
	if utils.window.valid(state.win) then
		vim.wo[state.win].cursorline = false
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
