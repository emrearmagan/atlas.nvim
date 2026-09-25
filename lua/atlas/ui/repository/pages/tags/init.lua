local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local diff = require("atlas.pulls.diff")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local info = require("atlas.ui.popups.info")
local history = require("atlas.ui.repository.pages.branches.git")
local keymaps = require("atlas.ui.repository.pages.tags.keymaps")
local renderer = require("atlas.ui.repository.pages.tags.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryTags
---@field buf integer
---@field win integer
---@field navigation_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field tags AtlasRepositoryTag[]|"loading"|string
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field root string|nil
---@field expanded string|nil
---@field line_map table<integer, RepositoryTagSelection>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field group integer

---@class RepositoryTagSelection
---@field tag AtlasRepositoryTag
---@field detail integer|nil

---@type table<integer, RepositoryTags>
local states = {}

local M = {
	key = "tags",
	label = "Tags",
	icon = icons.pulls("tag"),
}
local namespace = vim.api.nvim_create_namespace("atlas.repository.tags")

---@param state RepositoryTags
---@return AtlasRepositoryTag|nil
local function tag_at_cursor(state)
	local selection = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
	return selection and selection.tag
end

---@param state RepositoryTags
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(state.win)
	local selection = state.line_map[cursor[1]]
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	state.line_map = {}
	local tags = state.tags
	local message
	local hl_group = "AtlasTextMuted"
	if tags == "loading" then
		message = state.spinner:text("Loading tags...")
		hl_group = "Normal"
	elseif type(tags) == "string" then
		message = tags
		hl_group = "AtlasLogError"
	elseif #tags == 0 then
		message = "No tags found"
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
	local selected_row
	for row, entry in pairs(line_map) do
		if selection and entry.tag.name == selection.tag.name then
			if not entry.detail then
				selected_row = selected_row or row
			end
			if selection.detail == entry.detail then
				selected_row = row
				break
			end
		end
	end
	if selected_row then
		vim.api.nvim_win_set_cursor(state.win, { selected_row, cursor[2] })
	end
end

---@param state RepositoryTags
---@param page integer|nil
local function load(state, page)
	local repository = state.provider.capabilities.repository
	if not repository then
		state.tags = "Tags are not available for this provider"
		render(state)
		return
	end
	state.requests.cancel()
	state.requests = requests.new()
	state.page = page or 1
	if state.page == 1 then
		state.cursors = {}
	end
	state.next_cursor = nil
	state.tags = "loading"
	state.spinner:start()
	render(state)
	state.statusline:notify("loading", "Loading tags...")
	state.requests.run(function(done)
		return repository.fetch_tags(state.repo, {
			cursor = state.cursors[state.page],
		}, done)
	end, function(tags, err, next_cursor)
		state.spinner:stop()
		state.statusline:clear_notice()
		state.tags = tags or err or "Failed to load tags"
		state.next_cursor = next_cursor
		state.cursors[state.page + 1] = next_cursor
		render(state)
		if utils.window.valid(state.win) and state.line_map[1] then
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end
	end)
end

---@param state RepositoryTags
local function search(state)
	local repository = state.provider.capabilities.repository
	if not repository then
		return
	end
	local tags = state.tags
	picker.search({
		title = "Tags",
		initial_items = type(tags) == "table" and tags or {},
		key = function(tag)
			return tag.name
		end,
		format_item = function(tag)
			return tag.name
		end,
		preview_item = function(tag, done)
			done(renderer.preview(tag))
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_tags(state.repo, { search = query }, finish)
			end, done)
		end,
		on_select = function(tag)
			if not tag or states[state.buf] ~= state or not utils.window.valid(state.win) then
				return
			end
			state.requests.cancel()
			state.requests = requests.new()
			for row, entry in pairs(state.line_map) do
				if entry.tag.name == tag.name and not entry.detail then
					vim.api.nvim_set_current_win(state.win)
					vim.api.nvim_win_set_cursor(state.win, { row, 0 })
					return
				end
			end
			state.page = 1
			state.cursors = {}
			state.next_cursor = nil
			state.expanded = nil
			state.tags = { tag }
			state.spinner:stop()
			state.statusline:clear_notice()
			render(state)
			vim.api.nvim_set_current_win(state.win)
			vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
		end,
	})
end

---@param state RepositoryTags
local function open_diff(state)
	local tag = tag_at_cursor(state)
	if not tag then
		return
	end
	if not state.root then
		notify.warn("Configure this repository under pulls.repo_config.paths to open diffs")
		return
	end
	if tag.hash == "" then
		notify.warn("This tag has no target commit")
		return
	end
	local parent = tag.hash .. "^"
	local exists = git.check_commits(state.root, { tag.hash, parent })
	if not exists[1] then
		notify.warn("This tag's commit is not available in the local repository")
		return
	end
	if not exists[2] then
		notify.warn("This commit has no local first parent to compare")
		return
	end
	diff.open_range({ root = state.root, base = parent, head = tag.hash }, function(err)
		if err then
			notify.error(err)
		end
	end)
end

---@param opts { buf: integer, win: integer, navigation_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryTags
	local state = {
		buf = opts.buf,
		win = opts.win,
		navigation_buf = opts.navigation_buf,
		repo = opts.repo,
		provider = opts.provider,
		tags = "loading",
		page = 1,
		cursors = {},
		root = history.resolve(opts.repo),
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		group = vim.api.nvim_create_augroup("AtlasRepositoryTags" .. opts.buf, { clear = true }),
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
			if state.tags ~= "loading" and state.next_cursor then
				load(state, state.page + 1)
			end
		end,
		previous_page = function()
			if state.tags ~= "loading" and state.page > 1 then
				load(state, state.page - 1)
			end
		end,
		select = function()
			local tag = tag_at_cursor(state)
			if tag then
				state.expanded = state.expanded ~= tag.name and tag.name or nil
				render(state)
			end
		end,
		details = function()
			info.toggle({
				source_win = state.win,
				content = function(line)
					local selection = state.line_map[line]
					if selection then
						return renderer.preview(selection.tag)
					end
				end,
			})
		end,
		diff = function()
			open_diff(state)
		end,
		browser = function()
			local tag = tag_at_cursor(state)
			if tag then
				if tag.url and tag.url ~= "" then
					vim.ui.open(tag.url)
				else
					notify.warn("No URL available for this tag")
				end
			end
		end,
		copy = function()
			local tag = tag_at_cursor(state)
			if not tag then
				return
			end
			vim.fn.setreg("+", tag.hash)
			notify.success("Copied commit SHA")
		end,
		copy_url = function()
			local tag = tag_at_cursor(state)
			if tag then
				if tag.url and tag.url ~= "" then
					vim.fn.setreg("+", tag.url)
					notify.success("Copied tag URL")
				else
					notify.warn("No URL available for this tag")
				end
			end
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
