local M = {}

local window = require("atlas.issues.ui.dashboard.window")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.issues.state")
local renderer = require("atlas.issues.ui.dashboard.renderer")
local navigation = require("atlas.issues.ui.dashboard.navigation")
local controller = require("atlas.issues.ui.dashboard.controller")
local keymaps = require("atlas.issues.ui.dashboard.keymaps")
local detail = require("atlas.issues.ui.detail")
local detail_window = require("atlas.issues.ui.detail.window")
local starred = require("atlas.core.starred")
local bookmarks = require("atlas.ui.shared.bookmarks")
local notifications = require("atlas.ui.notifications")
local ns = vim.api.nvim_create_namespace("atlas.ui")

function M.render()
	local win = window.win()
	local buf = window.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local lines, spans, line_map = renderer.render({
		width = width,
	})
	window.line_map = line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	utils.apply_spans(buf, ns, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	navigation.highlight_current_item()
end

function M.resize()
	M.render()
	local win = window.win()
	if win == nil then
		return
	end

	-- When the window gets narrower (like when the detail panel opens) it can stay scrolled sideways, so scroll back.
	vim.api.nvim_win_call(win, function()
		vim.fn.winrestview({ leftcol = 0 })
	end)
	navigation.keep_board_selection()
end

---@param issue Issue
local function open_detail(issue)
	detail.open(issue, {
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

---@param item { issue: Issue|nil }|nil
function M.select(item)
	if item and item.issue and detail_window.is_open(vim.api.nvim_get_current_tabpage()) then
		open_detail(item.issue)
	end
end

function M.toggle_detail()
	if detail_window.is_open(vim.api.nvim_get_current_tabpage()) then
		detail.close()
		return
	end
	local item = navigation.current_item()
	if item and item.issue then
		open_detail(item.issue)
	end
end

function M.next_detail_tab()
	if detail.is_open() then
		detail.next_tab()
	end
end

function M.prev_detail_tab()
	if detail.is_open() then
		detail.prev_tab()
	end
end

---@param provider IssuesProvider
---@param opts { initial_view: IssuesViewConfig|nil }|nil
function M.init(provider, opts)
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.views = provider.views()
	state.query = ""
	state.error = nil
	state.set_issues({})
	state.current_page = 1
	state.page_history = {}
	state.collapsed_issue_keys = {}
	navigation.reset()

	state.starred_items = starred.list("issues", provider.id) or {}
	state.bookmarks = bookmarks.new(provider.id, "issues")
	state.view = (opts and opts.initial_view) or bookmarks.views(state.views, state.bookmarks, state.starred_items)[1]

	window.statusline:clear_items()

	local buf = window.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	controller.switch_view(state.view)

	if provider.capabilities.notifications then
		notifications.refresh(provider, M.render)
	end
end

return M
