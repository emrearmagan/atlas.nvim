local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local discussions = require("atlas.providers.github.discussions")
local panel = require("atlas.providers.github.ui.repository.pages.discussions.panel")
local keymaps = require("atlas.providers.github.ui.repository.pages.discussions.keymaps")
local renderer = require("atlas.providers.github.ui.repository.pages.discussions.renderer")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local prompt = require("atlas.ui.prompt")
local emojis = require("atlas.ui.shared.emojis")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryDiscussions
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field statusline AtlasStatusline
---@field discussions GitHubDiscussion[]|"loading"|string
---@field query string
---@field categories GitHubDiscussionCategory[]
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field line_map table<integer, GitHubDiscussion>
---@field panel GitHubDiscussionPanel|nil
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field keymaps table<string, AtlasHelpKeyItem[]>

local M = { key = "discussions", label = "Discussions", icon = icons.get("conversation") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.discussions")
---@type table<integer, RepositoryDiscussions>
local states = {}

---@param state RepositoryDiscussions
---@return GitHubDiscussion|nil
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryDiscussions
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)

	local items = state.discussions
	if type(items) == "string" then
		local message = items == "loading" and state.spinner:text("Loading discussions...") or items
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = items == "loading" and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	if #items == 0 then
		utils.buffer.center_message(state.buf, state.win, "No discussions found", lines)
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

---@param state RepositoryDiscussions
local function load(state)
	state.requests.cancel()
	state.requests = requests.new()
	state.discussions = "loading"
	state.next_cursor = nil
	state.spinner:start()
	state.statusline:notify("loading", "Loading discussions...")
	render(state)

	state.requests.run(function(done)
		return discussions.fetch(state.repo, {
			query = state.query,
			cursor = state.cursors[state.page],
		}, done)
	end, function(page, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		if not page then
			state.discussions = err or "Unable to load discussions"
			render(state)
			return
		end

		state.discussions = page.items
		state.categories = page.categories
		state.next_cursor = page.next_cursor
		render(state)
		if #page.items > 0 and utils.window.valid(state.win) then
			vim.api.nvim_win_set_cursor(state.win, { 3, 0 })
		end
	end)
end

---@param state RepositoryDiscussions
---@param query string
local function search(state, query)
	if states[state.buf] == state then
		state.query = query
		state.page, state.cursors = 1, {}
		load(state)
	end
end

---@param state RepositoryDiscussions
local function edit_query(state)
	prompt.open({
		name = "AtlasDiscussionSearch",
		prompt = "Discussion search: ",
		default = state.query .. " ",
		complete = function(arglead)
			local items = { "repo:", "is:", "author:", "category:", "label:", "sort:" }
			if arglead:match("^is:") then
				items = { "is:open", "is:closed", "is:answered", "is:unanswered", "is:locked", "is:unlocked" }
			end

			return vim.tbl_filter(function(item)
				return item:sub(1, #arglead) == arglead
			end, items)
		end,
		on_submit = function(query)
			query = vim.trim(query)
			if query ~= "" then
				search(state, query)
			end
		end,
	})
end

---@param state RepositoryDiscussions
local function toggle_state(state)
	local query = state.query
	if query:find("is:closed", 1, true) then
		query = query:gsub("is:closed", "is:open")
	elseif query:find("is:open", 1, true) then
		query = query:gsub("is:open", "is:closed")
	else
		query = query .. " is:closed"
	end

	search(state, query)
end

---@param state RepositoryDiscussions
local function select_category(state)
	if #state.categories == 0 then
		return
	end

	local all = { name = "All categories" }
	local items, selected = { all }, 1
	for index, category in ipairs(state.categories) do
		table.insert(items, category)
		if state.query:find('category:"' .. category.name .. '"', 1, true) then
			selected = index + 1
		end
	end

	picker.select({
		title = "Discussion categories",
		items = items,
		initial_index = selected,
		format_item = function(category)
			if category == all then
				return icons.get("conversation") .. "  " .. all.name
			end

			return emojis.get(category.emoji) .. "  " .. category.name
		end,
		on_select = function(category)
			if not category then
				return
			end

			local query = vim.trim((state.query:gsub('%s*category:"[^"]*"', ""):gsub("%s*category:%S+", "")))
			if category ~= all then
				query = query .. ' category:"' .. category.name .. '"'
			end

			search(state, query)
		end,
	})
end

---@param state RepositoryDiscussions
---@param number integer
local function open_panel(state, number)
	state.panel = panel.open(state.panel, {
		anchor = state.win,
		repo = state.repo,
		statusline = state.statusline,
		number = number,
	})
end

---@param state RepositoryDiscussions
local function refresh(state)
	state.page, state.cursors = 1, {}
	load(state)
end

---@param state RepositoryDiscussions
local function next_page(state)
	if state.discussions ~= "loading" and state.next_cursor then
		state.page = state.page + 1
		state.cursors[state.page] = state.next_cursor
		load(state)
	end
end

---@param state RepositoryDiscussions
local function previous_page(state)
	if state.discussions ~= "loading" and state.page > 1 then
		state.page = state.page - 1
		load(state)
	end
end

---@param state RepositoryDiscussions
local function open_discussion(state)
	local discussion = current(state)
	if discussion then
		open_panel(state, discussion.number)
	end
end

---@param state RepositoryDiscussions
local function open_in_browser(state)
	local discussion = current(state)
	if discussion and discussion.url ~= "" then
		vim.ui.open(discussion.url)
	end
end

---@param state RepositoryDiscussions
local function copy_url(state)
	local discussion = current(state)
	if discussion and discussion.url ~= "" then
		vim.fn.setreg("+", discussion.url)
		notify.success("Copied URL")
	end
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline, ctx: { number?: integer } }
function M.open(opts)
	---@type RepositoryDiscussions
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		statusline = opts.statusline,
		discussions = "loading",
		query = string.format("repo:%s is:open sort:updated-desc", opts.repo.full_name),
		categories = {},
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
		copy_url = copy_url,
		edit_query = edit_query,
		next_page = next_page,
		open_discussion = open_discussion,
		open_in_browser = open_in_browser,
		previous_page = previous_page,
		refresh = refresh,
		select_category = select_category,
		toggle_state = toggle_state,
	})

	load(state)
	if opts.ctx.number then
		open_panel(state, opts.ctx.number)
	end
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
	panel.close(state.panel)
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	for group, items in pairs(state.keymaps) do
		help.remove(group, items, { buffer = state.sidebar_buf })
	end
end

return M
