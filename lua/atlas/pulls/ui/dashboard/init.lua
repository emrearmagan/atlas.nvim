local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local ui_state = require("atlas.ui.state")
local statusline = require("atlas.ui.statusline")
local ns = vim.api.nvim_create_namespace("atlas.ui")

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans or {}) do
		vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

function M.render()
	local win = dashboard_host.win()
	local buf = dashboard_host.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local height = vim.api.nvim_win_get_height(win)
	local lines, spans, line_map = require("atlas.pulls.ui.dashboard.renderer").render({
		width = width,
		height = height,
	})

	ui_state.line_map = line_map or {}

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param pr PullRequest
local function open_detail(pr)
	local state = require("atlas.pulls.state")
	require("atlas.pulls.ui.detail").open(pr, {
		provider = state.provider,
		on_update = require("atlas.pulls.ui.dashboard.controller").apply_action_result,
	})
end

---@param item table|nil
function M.select(item)
	if type(item) ~= "table" or (item.kind ~= "pr" and item.kind ~= "pr_meta") or type(item.pr) ~= "table" then
		return
	end
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		open_detail(item.pr)
		return
	end
	local repo_detail = require("atlas.pulls.ui.repo_detail")
	if repo_detail.is_open() then
		repo_detail.select(item.repo)
	end
end

function M.toggle_detail()
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	local item = require("atlas.ui.navigation").current_item()
	if type(item) == "table" and (item.kind == "pr" or item.kind == "pr_meta") and type(item.pr) == "table" then
		open_detail(item.pr)
	end
end

function M.next_detail_tab()
	local repo_detail = require("atlas.pulls.ui.repo_detail")
	if repo_detail.is_open() then
		repo_detail.next_tab()
	elseif require("atlas.pulls.ui.detail").is_open() then
		require("atlas.pulls.ui.detail").next_tab()
	end
end

function M.prev_detail_tab()
	local repo_detail = require("atlas.pulls.ui.repo_detail")
	if repo_detail.is_open() then
		repo_detail.prev_tab()
	elseif require("atlas.pulls.ui.detail").is_open() then
		require("atlas.pulls.ui.detail").prev_tab()
	end
end

---@param provider PullsProvider
---@param opts? { initial_view?: AtlasPullsViewConfig }
function M.init(provider, opts)
	local state = require("atlas.pulls.state")
	local controller = require("atlas.pulls.ui.dashboard.controller")
	local keymaps = require("atlas.pulls.ui.dashboard.keymaps")
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.provider_views = provider.views()

	local notifications = require("atlas.ui.notifications")
	notifications.set_provider(provider)

	require("atlas.pulls.ui.highlights").setup()
	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	local views = require("atlas.ui.shared.bookmarks").views(provider.id, "pulls", state.provider_views)
	state.active_view = (opts and opts.initial_view) or views[1]

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
		keymaps.register(buf, views)
	end

	M.render()
	controller.switch_view(state.active_view)

	if provider.capabilities.notifications then
		notifications.refresh({ force_load = false, on_done = M.render })
	end
end

return M
