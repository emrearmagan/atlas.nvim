local resolver = require("atlas.core.keymaps")
local requests = require("atlas.core.requests")
local spinner = require("atlas.ui.components.spinner")
local help = require("atlas.ui.popups.help")
local renderer = require("atlas.ui.repository.pages.overview.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryOverview
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field details AtlasRepositoryDetails|"loading"|string
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field statusline AtlasStatusline
---@field group integer
---@field refresh_keys string[]

---@type table<integer, RepositoryOverview>
local states = {}

local M = {
	key = "overview",
	label = "Overview",
	icon = icons.general("overview"),
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
	local repository = state.provider.capabilities.repository
	if not repository then
		state.details = "Repository details are not available"
		render(state)
		return
	end
	state.requests.cancel()
	state.requests = requests.new()
	state.details = "loading"
	state.spinner:start()
	render(state)
	vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
	state.statusline:notify("loading", "Loading overview...")
	state.requests.run(function(done)
		return repository.fetch_details(state.repo, done)
	end, function(details, err)
		state.spinner:stop()
		if details then
			for key in pairs(state.repo) do
				state.repo[key] = details[key]
			end
			for key, value in pairs(details) do
				state.repo[key] = value
			end
		end
		state.details = details or err or "Failed to load repository"
		render(state)
		state.statusline:clear_notice()
	end)
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
		provider = opts.provider,
		statusline = opts.statusline,
		requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryOverview" .. opts.buf, { clear = true }),
		refresh_keys = resolver.resolve("ui.refresh") or {},
	}
	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end
	vim.bo[state.buf].filetype = "markdown"
	vim.wo[state.win].wrap = true
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function()
			render(state)
		end,
	})
	for _, buf in ipairs({ state.buf, state.sidebar_buf }) do
		help.register("Overview", {
			{
				key = state.refresh_keys,
				desc = "Reload overview",
				callback = function()
					load(state)
				end,
				opts = { nowait = true, silent = true },
			},
		}, { buffer = buf })
	end
	render(state)
end

---@param buf integer
function M.close(buf)
	local state = states[buf]
	states[buf] = nil
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	for _, buffer in ipairs({ state.buf, state.sidebar_buf }) do
		help.remove("Overview", { { key = state.refresh_keys } }, { buffer = buffer })
	end
	if utils.window.valid(state.win) then
		vim.wo[state.win].wrap = false
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
