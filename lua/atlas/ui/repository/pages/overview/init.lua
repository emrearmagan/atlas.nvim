local requests = require("atlas.core.requests")
local spinner = require("atlas.ui.components.spinner")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.ui.repository.pages.overview.keymaps")
local renderer = require("atlas.ui.repository.pages.overview.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryOverview
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field repository AtlasRepositoryCapability
---@field details AtlasRepositoryDetails|"loading"|string
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field keymaps AtlasHelpKeyItem[]

---@type table<integer, RepositoryOverview>
local states = {}

local M = {
	key = "overview",
	label = "Overview",
	icon = icons.get("overview"),
}
local namespace = vim.api.nvim_create_namespace("atlas.repository.overview")

---@param state RepositoryOverview
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	local details = state.details
	if type(details) == "string" then
		local loading = details == "loading"
		local text = loading and state.spinner:text("Loading...") or details
		utils.buffer.center_message(state.buf, state.win, text)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = loading and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, spans = renderer.render(details, vim.api.nvim_win_get_width(state.win))

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

---@param state RepositoryOverview
local function load(state)
	state.requests.cancel()
	state.requests = requests.new()
	state.details = "loading"
	state.spinner:start()
	render(state)
	vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
	state.statusline:notify("loading", "Loading overview...")
	state.requests.run(function(done)
		return state.repository.fetch_details(state.repo, done)
	end, function(details, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		if details then
			for key, value in pairs(details) do
				state.repo[key] = value
			end
		end

		state.details = details or err or "Failed to load repository"
		render(state)
	end)
end

---@param state RepositoryOverview
local function open_in_browser(state)
	if state.repo.html_url then
		vim.ui.open(state.repo.html_url)
	end
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline }
function M.open(opts)
	---@type RepositoryOverview
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		details = opts.repo,
		repository = assert(opts.provider.capabilities.repository),
		statusline = opts.statusline,
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

	vim.wo[state.win].wrap = true
	vim.wo[state.win].linebreak = true
	keymaps.setup(state, { load = load, open_in_browser = open_in_browser })
	render(state)
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
	states[buf] = nil
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	help.remove("General", state.keymaps, { buffer = state.sidebar_buf })
end

return M
