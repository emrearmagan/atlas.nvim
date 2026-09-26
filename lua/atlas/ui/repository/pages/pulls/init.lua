local opener = require("atlas.commands.open")
local review = require("atlas.commands.review")
local resolver = require("atlas.core.keymaps")
local requests = require("atlas.core.requests")
local providers = require("atlas.providers")
local pull_list = require("atlas.pulls.ui.components.pull_list")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryPulls
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field provider PullsProvider|nil
---@field view AtlasPullsViewConfig|nil
---@field statusline AtlasStatusline
---@field pulls PullRequest[]|string
---@field filter PullsStateFilter
---@field page integer
---@field cursors table<integer, table<string, string>>
---@field next_cursor table<string, string>|nil
---@field total_pages integer|nil
---@field line_map table<integer, PullRequest>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field group integer
---@field keymaps table<integer, AtlasHelpKeyItem[]>

local M = { key = "pulls", label = "Pull Requests", icon = icons.pulls("pr") }
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
	local cursor = vim.api.nvim_win_get_cursor(state.win)
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
	local header, spans = " ", {}
	for _, filter in ipairs(filters) do
		local label = filter:gsub("^%l", string.upper)
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
	local lines = { header, "" }
	if #pulls == 0 then
		utils.buffer.center_message(state.buf, state.win, "No " .. state.filter .. " pull requests found.", lines)
	else
		local table_lines, line_map, table_spans = pull_list.render({
			width = vim.api.nvim_win_get_width(state.win),
			provider_id = state.provider and state.provider.id,
		}, pulls)
		local offset = #lines
		utils.append_block(lines, spans, { lines = table_lines, highlights = table_spans })
		for row, item in pairs(line_map) do
			if item.pr then
				state.line_map[offset + row] = item.pr
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
	if #pulls == 0 then
		return
	end
	vim.api.nvim_win_set_cursor(state.win, { math.min(cursor[1], #lines), cursor[2] })
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
	view._states = { state.filter }
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
local function search(state)
	local pulls = state.pulls
	if type(pulls) == "string" or #pulls == 0 then
		return
	end
	picker.select({
		title = "Pull requests on this page",
		items = pulls,
		format_item = function(pr)
			return string.format("%s  %s  %s", pr.id, pr.title:gsub("%c", " "), pr.author.name)
		end,
		on_select = function(pr)
			if not pr or states[state.buf] ~= state or not utils.window.valid(state.win) then
				return
			end
			for row = 1, vim.api.nvim_buf_line_count(state.buf) do
				local entry = state.line_map[row]
				if entry and entry.id == pr.id then
					vim.api.nvim_set_current_win(state.win)
					vim.api.nvim_win_set_cursor(state.win, { row, 0 })
					return
				end
			end
		end,
	})
end

---@param state RepositoryPulls
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
	help.register("Pull Requests", items, { buffer = buf })
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
		view = provider and target and provider.view_for_target(target),
		statusline = opts.statusline,
		pulls = "loading",
		filter = "open",
		page = 1,
		cursors = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryPulls" .. opts.buf, { clear = true }),
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
			"Refresh pull requests",
			function()
				state.page, state.cursors, state.next_cursor = 1, {}, nil
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
			resolver.resolve("ui.next_page"),
			"Next pull requests",
			function()
				if state.pulls == "loading" or not state.next_cursor then
					return
				end
				state.page = state.page + 1
				state.cursors[state.page] = state.next_cursor
				load(state)
			end,
		},
		{
			resolver.resolve("ui.previous_page"),
			"Previous pull requests",
			function()
				if state.pulls ~= "loading" and state.page > 1 then
					state.page = state.page - 1
					load(state)
				end
			end,
		},
	}
	for _, filter in ipairs(filters) do
		actions[#actions + 1] = {
			resolver.resolve("pulls.filters." .. filter),
			"Show " .. filter .. " pull requests",
			function()
				state.filter = filter
				state.page, state.cursors, state.next_cursor = 1, {}, nil
				load(state)
			end,
		}
	end
	register(state, state.sidebar_buf, actions)
	local panel_keys = resolver.resolve("ui.select") or {}
	if not vim.tbl_contains(panel_keys, "p") then
		panel_keys[#panel_keys + 1] = "p"
	end
	vim.list_extend(actions, {
		{
			resolver.resolve("pulls.open_diff"),
			"Open pull request diff",
			function()
				local pr = current(state)
				if pr then
					review.open(pr.link.html)
				end
			end,
		},
		{
			panel_keys,
			"Open pull request panel",
			function()
				local pr = current(state)
				if pr then
					opener.open(pr.link.html)
				end
			end,
		},
		{
			resolver.resolve("ui.open_in_browser"),
			"Open pull request in browser",
			function()
				local pr = current(state)
				if pr then
					vim.ui.open(pr.link.html)
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
		help.remove("Pull Requests", items, { buffer = buffer })
	end
	if utils.window.valid(state.win) then
		vim.wo[state.win].cursorline = false
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
