local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local ui_state = require("atlas.ui.state")
local utils = require("atlas.ui.shared.utils")
local statusline = require("atlas.ui.statusline")
local ns = vim.api.nvim_create_namespace("atlas.ui")

function M.render()
	local win = dashboard_host.win()
	local buf = dashboard_host.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local navigation = require("atlas.ui.navigation")
	local selected = navigation.current_item()
	local lines, spans, line_map = require("atlas.issues.ui.dashboard.renderer").render({
		width = width,
	})
	local state = require("atlas.issues.state")
	local board = state.view_layout(state.search_view()) == "board" and not state.error

	ui_state.line_map = line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	utils.apply_spans(buf, ns, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	if board then
		navigation.restore_board_selection(selected)
	else
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview({ leftcol = 0 })
		end)
	end
	navigation.highlight_current_item()
end

---@param issue Issue
local function open_detail(issue)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	require("atlas.issues.ui.detail").open(issue, {
		provider = state.provider,
		on_update = function(updated, result)
			if result then
				controller.apply_action_result(result)
			elseif updated then
				controller.update_issue(updated)
			end
		end,
	})
end

---@param item { kind: string, _issue: Issue|nil }|nil
function M.select(item)
	local detail = require("atlas.ui.detail")
	if not detail.is_open(vim.api.nvim_get_current_tabpage()) then
		return
	end
	if type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

function M.toggle_detail()
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	local item = require("atlas.ui.navigation").current_item()
	if type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

function M.next_detail_tab()
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.next_tab()
	end
end

function M.prev_detail_tab()
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.prev_tab()
	end
end

---@param provider IssuesProvider
---@param opts { initial_view: IssuesViewConfig|nil }|nil
function M.init(provider, opts)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local keymaps = require("atlas.issues.ui.dashboard.keymaps")
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.views = provider.views()
	state.query = ""

	local notifications = require("atlas.ui.notifications")
	notifications.set_provider(provider)
	state.error = nil
	state.set_issues({})
	state.current_page = 1
	state.page_history = {}
	state.collapsed_issue_keys = {}

	state.starred_items = require("atlas.core.starred").list("issues", provider.id) or {}
	local bookmarks = require("atlas.ui.shared.bookmarks")
	state.bookmarks = bookmarks.new(provider.id, "issues")
	state.view = (opts and opts.initial_view) or bookmarks.views(state.views, state.bookmarks, state.starred_items)[1]

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	controller.switch_view(state.view)

	if provider.capabilities.notifications then
		notifications.refresh({ on_done = M.render })
	end
end

return M
