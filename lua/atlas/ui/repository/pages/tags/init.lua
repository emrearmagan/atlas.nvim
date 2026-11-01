local checkout = require("atlas.core.git.checkout")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local diff = require("atlas.pulls.diff")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local info = require("atlas.ui.popups.info")
local keymaps = require("atlas.ui.repository.pages.tags.keymaps")
local renderer = require("atlas.ui.repository.pages.tags.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryTags
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field repository AtlasRepositoryCapability
---@field tags AtlasRepositoryTag[]|"loading"|string
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field root string|nil
---@field root_loading boolean
---@field root_error string|nil
---@field root_request AtlasRequestScope
---@field expanded string|nil
---@field line_map table<integer, RepositoryTagSelection>
---@field closed boolean
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field keymaps table<string, AtlasHelpKeyItem[]>

---@class RepositoryTagSelection
---@field tag AtlasRepositoryTag
---@field detail integer|nil

local M = { key = "tags", label = "Tags", icon = icons.get("tag") }
---@type table<integer, RepositoryTags>
local states = {}

local namespace = vim.api.nvim_create_namespace("atlas.repository.tags")

---@param state RepositoryTags
---@return AtlasRepositoryTag|nil
local function current(state)
	local selection = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
	return selection and selection.tag
end

---@param state RepositoryTags
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

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

	local lines, spans, line_map = renderer.render(state, vim.api.nvim_win_get_width(state.win))
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
end

---@param state RepositoryTags
---@param page integer|nil
local function load(state, page)
	local repository = state.repository
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
	local repository = state.repository
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
			if not tag or state.closed or not utils.window.valid(state.win) then
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
	local tag = current(state)
	if not tag then
		return
	end

	if not state.root then
		local reason = state.root_error and (" (" .. state.root_error .. ")") or ""
		notify.warn(
			state.root_loading and "Resolving local repository..."
				or ("Configure this repository under pulls.repo_config.paths to open diffs" .. reason)
		)

		return
	end

	if tag.hash == "" then
		notify.warn("This tag has no target commit")
		return
	end

	diff.open_commit({ root = state.root, commit = tag.hash }, function(err)
		if err then
			notify.error(err)
		end
	end)
end

---@param state RepositoryTags
local function next_page(state)
	if state.tags ~= "loading" and state.next_cursor then
		load(state, state.page + 1)
	end
end

---@param state RepositoryTags
local function previous_page(state)
	if state.tags ~= "loading" and state.page > 1 then
		load(state, state.page - 1)
	end
end

---@param state RepositoryTags
local function toggle_details(state)
	local tag = current(state)
	if not tag then
		return
	end

	state.expanded = state.expanded ~= tag.name and tag.name or nil
	render(state)
	for row, entry in pairs(state.line_map) do
		if entry.tag.name == tag.name and not entry.detail then
			vim.api.nvim_win_set_cursor(state.win, { row, 0 })
			break
		end
	end
end

---@param state RepositoryTags
local function show_details(state)
	info.toggle({
		source_win = state.win,
		content = function(line)
			local selection = state.line_map[line]
			if selection then
				return renderer.preview(selection.tag)
			end
		end,
	})
end

---@param state RepositoryTags
local function open_in_browser(state)
	local tag = current(state)
	if tag and tag.url and tag.url ~= "" then
		vim.ui.open(tag.url)
	elseif tag then
		notify.warn("No URL available for this tag")
	end
end

---@param state RepositoryTags
local function copy_sha(state)
	local tag = current(state)
	if tag then
		vim.fn.setreg("+", tag.hash)
		notify.success("Copied commit SHA")
	end
end

---@param state RepositoryTags
local function copy_url(state)
	local tag = current(state)
	if tag and tag.url and tag.url ~= "" then
		vim.fn.setreg("+", tag.url)
		notify.success("Copied tag URL")
	elseif tag then
		notify.warn("No URL available for this tag")
	end
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryTags
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		provider = opts.provider,
		repository = assert(opts.provider.capabilities.repository),
		tags = "loading",
		page = 1,
		cursors = {},
		root_request = requests.new(),
		root_loading = true,
		closed = false,
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		statusline = opts.statusline,
		keymaps = {},
	}

	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	vim.wo[state.win].cursorline = true
	keymaps.setup(state, {
		copy_sha = copy_sha,
		copy_url = copy_url,
		load = load,
		next_page = next_page,
		open_diff = open_diff,
		open_in_browser = open_in_browser,
		previous_page = previous_page,
		search = search,
		show_details = show_details,
		toggle_details = toggle_details,
	})

	load(state)
	state.root_request.run(function(done)
		return checkout.resolve_repo_root(opts.repo.full_name, opts.repo.html_url, done)
	end, function(root, err)
		if state.closed or not utils.window.has_buffer(state.win, state.buf) then
			return
		end

		state.root = root
		state.root_error = err
		state.root_loading = false
	end)
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
	state.closed = true
	info.close(state.win)
	state.root_request.cancel()
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	for group, items in pairs(state.keymaps) do
		help.remove(group, items, { buffer = state.sidebar_buf })
	end
end

return M
