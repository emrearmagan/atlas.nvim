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
---@field release AtlasRepositoryReleaseDetails|string
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
	if type(release) == "string" then
		local message = release == "loading" and state.spinner:text("Loading release...") or release
		utils.buffer.center_message(state.buf, state.win, message:gsub("[\r\n]+", " "))
		vim.api.nvim_buf_set_extmark(state.buf, namespace, vim.api.nvim_buf_line_count(state.buf) - 1, 0, {
			line_hl_group = release == "loading" and "Normal" or "AtlasTextMuted",
		})
		return
	end
	local lines, line_map, spans = renderer.render(release)
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
	vim.bo[state.buf].filetype = "markdown"
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
	vim.bo[state.buf].filetype = "atlas.repository"
	state.spinner:start()
	state.statusline:notify("loading", "Loading release...")
	render(state)
	state.requests.run(function(done)
		return fetch_release(state.repo, { id = id }, done)
	end, function(release, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		state.release = release or err or "No releases found"
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
	local repository = state.provider.capabilities.repository
	local fetch = repository and repository.fetch_releases
	if not fetch then
		return
	end
	state.requests.cancel()
	state.requests = requests.new()
	state.statusline:notify("loading", "Loading releases...")
	state.requests.run(function(done)
		return fetch(state.repo, {}, done)
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
	if type(state.release) == "string" then
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
		local keys = action[1]
		if keys and #keys > 0 then
			table.insert(items, {
				key = keys,
				desc = action[2],
				callback = action[3],
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
	vim.wo[state.win].wrap = true

	local actions = {
		{
			resolver.resolve("ui.refresh"),
			"Refresh release",
			function()
				load(state, state.selected_id)
			end,
		},
		{
			resolver.resolve("ui.search"),
			"Search releases",
			function()
				search(state)
			end,
		},
		{
			resolver.resolve("ui.next_page"),
			"Next release",
			function()
				change_release(state, 1)
			end,
		},
		{
			resolver.resolve("ui.previous_page"),
			"Previous release",
			function()
				change_release(state, -1)
			end,
		},
	}
	register(state, state.sidebar_buf, actions)
	local function current()
		return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
	end
	vim.list_extend(actions, {
		{
			resolver.resolve("ui.open_in_browser"),
			"Open in browser",
			function()
				local entry = current()
				if entry then
					vim.ui.open(entry.asset and entry.asset.url or entry.release.url)
				end
			end,
		},
		{
			resolver.resolve("ui.copy_id"),
			"Copy release tag",
			function()
				local entry = current()
				if entry then
					vim.fn.setreg("+", entry.release.tag)
					notify.success("Copied " .. entry.release.tag)
				end
			end,
		},
		{
			resolver.resolve("ui.copy_url"),
			"Copy URL",
			function()
				local entry = current()
				if entry then
					vim.fn.setreg("+", entry.asset and entry.asset.url or entry.release.url)
					notify.success("Copied URL")
				end
			end,
		},
	})
	register(state, state.buf, actions)
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function(event)
			if
				type(state.release) == "string"
				and (event.event == "VimResized" or vim.tbl_contains(vim.v.event.windows, state.win))
			then
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
