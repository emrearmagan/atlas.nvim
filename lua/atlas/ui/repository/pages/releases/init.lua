local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local renderer = require("atlas.ui.repository.pages.releases.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryReleases
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field statusline AtlasStatusline
---@field release AtlasRepositoryReleaseDetails|string|nil
---@field releases AtlasRepositoryRelease[]|nil
---@field selected_id string|nil
---@field line_map table<integer, RepositoryReleaseSelection>
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field group integer
---@field keymaps table<integer, AtlasHelpKeyItem[]>

local M = {
	key = "releases",
	label = "Releases",
	icon = icons.pulls("tag"),
}
local namespace = vim.api.nvim_create_namespace("atlas.repository.releases")
---@type table<integer, RepositoryReleases>
local states = {}

---@param state RepositoryReleases
local function render(state)
	if not utils.window.valid(state.win) or not utils.buffer.valid(state.buf) then
		return
	end
	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local release = state.release
	if not release or type(release) == "string" then
		local message = release or "No releases found"
		local hl_group = release and "AtlasLogError" or "AtlasTextMuted"
		if release == "loading" then
			message = state.spinner:text("Loading release...")
			hl_group = "Normal"
		end
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = hl_group,
		})
		return
	end
	local lines, line_map, spans = renderer.render(release, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col or 0, {
			end_col = span.end_col,
			hl_group = span.hl_group,
			line_hl_group = span.line_hl_group,
		})
	end
	vim.bo[state.buf].modifiable = false
end

---@param state RepositoryReleases
---@param id string|nil
local function load(state, id)
	local repository = state.provider.capabilities.repository
	local fetch_release = repository and repository.fetch_release
	if not fetch_release then
		state.release = "Releases are not available for this provider"
		render(state)
		return
	end
	state.requests.cancel()
	state.requests = requests.new()
	state.selected_id = id
	state.release = "loading"
	state.spinner:start()
	state.statusline:notify("loading", "Loading release...")
	render(state)
	state.requests.run(function(done)
		return fetch_release(state.repo, { id = id }, done)
	end, function(release, err, status)
		state.spinner:stop()
		state.statusline:clear_notice()
		if not id and status == 404 then
			state.release = nil
		else
			state.release = release or err
		end
		render(state)
		vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
	end)
end

---@param state RepositoryReleases
---@param on_done fun(releases: AtlasRepositoryRelease[])
local function fetch_releases(state, on_done)
	if state.release == "loading" then
		return
	end
	if state.releases then
		on_done(state.releases)
		return
	end
	local repository = state.provider.capabilities.repository
	local fetch = repository and repository.fetch_releases
	if not fetch then
		return
	end
	state.requests.cancel()
	state.requests = requests.new()
	state.statusline:notify("loading", "Loading releases...")
	state.requests.run(function(done)
		return fetch(state.repo, done)
	end, function(releases, err)
		state.statusline:clear_notice()
		if not releases then
			notify.error(err or "Failed to load releases")
			return
		end
		if #releases == 0 then
			notify.info("No releases found")
			return
		end
		state.releases = releases
		on_done(releases)
	end)
end

---@param state RepositoryReleases
local function search(state)
	fetch_releases(state, function(releases)
		picker.select({
			title = "Releases",
			items = releases,
			format_item = function(release)
				local label = release.tag
				if release.name ~= release.tag then
					label = label .. "  " .. release.name
				end
				local date = utils.format_date(release.published_at)
				if date ~= "" then
					label = label .. "  " .. date
				end
				if release.draft then
					label = label .. "  [Draft]"
				elseif release.prerelease then
					label = label .. "  [Prerelease]"
				end
				return label
			end,
			on_select = function(release)
				if release and states[state.buf] == state then
					load(state, release.id)
					vim.api.nvim_set_current_win(state.win)
				end
			end,
		})
	end)
end

---@param state RepositoryReleases
---@param direction 1|-1
local function change_release(state, direction)
	if not state.release or type(state.release) == "string" then
		return
	end
	local id = state.release.id
	fetch_releases(state, function(releases)
		for index, release in ipairs(releases) do
			if release.id == id then
				local next_release = releases[index + direction]
				if next_release then
					load(state, next_release.id)
				else
					notify.info(direction == 1 and "No next release" or "No previous release")
				end
				return
			end
		end
	end)
end

---@param state RepositoryReleases
---@param buf integer
---@param actions table[]
local function register(state, buf, actions)
	local items = {}
	for _, action in ipairs(actions) do
		local keys = action.key
		if keys and #keys > 0 then
			table.insert(items, {
				key = keys,
				desc = action.desc,
				index = action.index,
				callback = action.callback,
				opts = { silent = true, nowait = true },
			})
		end
	end
	state.keymaps[buf] = items
	help.register("Releases", items, { buffer = buf })
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryReleases
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		provider = opts.provider,
		statusline = opts.statusline,
		release = "loading",
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryReleases" .. opts.buf, { clear = true }),
		keymaps = {},
	}
	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end
	vim.bo[state.buf].filetype = "atlas-ui.repository"
	vim.wo[state.win].wrap = true
	vim.wo[state.win].linebreak = true

	local actions = {
		{
			key = resolver.resolve("ui.refresh"),
			desc = "Refresh release",
			callback = function()
				state.releases = nil
				load(state, state.selected_id)
			end,
			index = 25,
		},
		{
			key = resolver.resolve("ui.search"),
			desc = "Search releases",
			callback = function()
				search(state)
			end,
			index = 20,
		},
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next release",
			callback = function()
				change_release(state, 1)
			end,
			index = 11,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous release",
			callback = function()
				change_release(state, -1)
			end,
			index = 10,
		},
	}
	register(state, state.sidebar_buf, actions)
	local function current()
		return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
	end
	vim.list_extend(actions, {
		{
			key = resolver.resolve("ui.open_in_browser"),
			desc = "Open in browser",
			callback = function()
				local entry = current()
				if entry then
					vim.ui.open(entry.asset and entry.asset.url or entry.release.url)
				end
			end,
			index = 33,
		},
		{
			key = resolver.resolve("ui.copy_id"),
			desc = "Copy release tag",
			callback = function()
				local entry = current()
				if entry then
					vim.fn.setreg("+", entry.release.tag)
					notify.success("Copied " .. entry.release.tag)
				end
			end,
			index = 40,
		},
		{
			key = resolver.resolve("ui.copy_url"),
			desc = "Copy URL",
			callback = function()
				local entry = current()
				if entry then
					vim.fn.setreg("+", entry.asset and entry.asset.url or entry.release.url)
					notify.success("Copied URL")
				end
			end,
			index = 41,
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
	states[buf] = nil
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	for buffer, items in pairs(state.keymaps) do
		help.remove("Releases", items, { buffer = buffer })
	end
	if utils.window.valid(state.win) then
		vim.wo[state.win].wrap = false
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
