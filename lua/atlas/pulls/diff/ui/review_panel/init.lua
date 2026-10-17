local keymap_resolver = require("atlas.core.keymaps")
local keymaps = require("atlas.pulls.diff.ui.review_panel.keymaps")
local renderer = require("atlas.pulls.diff.ui.review_panel.renderer")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.review_panel")
local filter_labels = { all = "All", unresolved = "Unresolved", mine = "Mine" }

---@class AtlasDiffReviewPanel
---@field data AtlasDiffResult
---@field buf integer
---@field win integer|nil
---@field group integer
---@field expanded table<string, boolean>
---@field line_map table<integer, AtlasDiffReviewPanelRow>
---@field filter AtlasDiffReviewPanelFilter

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keys = keymap_resolver.resolve(action)
	return keys and #keys > 0 and table.concat(keys, " / ") or nil
end

---@param state AtlasDiffReviewPanel
function M.render(state)
	if not state.win then
		return
	end
	local previous = state.expanded
	state.expanded = {}
	local function expanded(key)
		state.expanded[key] = previous[key] == true
		return state.expanded[key]
	end

	local lines, spans, line_map = renderer.render(state.data, state.filter, vim.api.nvim_win_get_width(state.win), {
		reply = key_label("pulls.review.add_comment"),
		add_task = key_label("pulls.review.add_task"),
		edit = key_label("ui.comments.edit"),
		delete = key_label("ui.delete"),
		toggle_resolved = key_label("pulls.review.toggle_resolved"),
	}, expanded)

	local filter_key = key_label("pulls.review.panel.cycle_filter")
	vim.wo[state.win].winbar = " Review%="
		.. filter_labels[state.filter]
		.. (filter_key and "  %#AtlasTextMuted#" .. filter_key:gsub("%%", "%%%%") .. " filter" or "")
		.. " "

	state.line_map = line_map
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param result AtlasDiffResult
---@param callbacks { on_select: fun(entry: AtlasDiffReviewPanelRow, focus: boolean), on_action: fun(id: AtlasReviewActionId, target: { comment?: PullsComment, note?: AtlasNote, review_entry?: PullsReviewHistoryEntry, pending?: boolean }), on_resize: fun() }
---@return AtlasDiffReviewPanel
function M.create(result, callbacks)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, string.format("Review [%d]", vim.api.nvim_get_current_tabpage()))
	---@type AtlasDiffReviewPanel
	local state = {
		data = result,
		buf = buf,
		group = vim.api.nvim_create_augroup("AtlasDiffReviewPanel" .. buf, { clear = true }),
		expanded = {},
		line_map = {},
		filter = "all",
	}
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas-ui.review"
	vim.bo[buf].modifiable = false

	keymaps.setup(state, {
		on_select = callbacks.on_select,
		on_action = callbacks.on_action,
		render = function()
			M.render(state)
		end,
		close = function()
			M.close(state)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(event)
			if tonumber(event.match) == state.win then
				state.win = nil
				vim.schedule(callbacks.on_resize)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = state.group,
		callback = function()
			if state.win and vim.tbl_contains(vim.v.event.windows, state.win) then
				M.render(state)
				callbacks.on_resize()
			end
		end,
	})
	return state
end

---@param state AtlasDiffReviewPanel
---@return integer
local function height(state)
	local configured = math.max(4, math.floor(state.data.options.review_panel.height))
	return math.min(configured, math.max(4, vim.o.lines - 8))
end

---@param state AtlasDiffReviewPanel
function M.resize(state)
	if state.win then
		vim.api.nvim_win_set_height(state.win, height(state))
		M.render(state)
	end
end

---@param state AtlasDiffReviewPanel
---@return integer
function M.open(state)
	if state.win then
		return state.win
	end
	state.win = vim.api.nvim_open_win(state.buf, false, {
		split = "below",
		win = -1,
		height = height(state),
	})
	local options = vim.wo[state.win][0]
	options.winfixheight = true
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.statuscolumn = ""
	options.winhighlight = ""
	options.foldcolumn = "0"
	options.fillchars = "eob: "
	options.wrap = false
	options.cursorline = true
	options.cursorcolumn = false
	options.foldenable = false
	options.diff = false
	options.scrollbind = false
	options.cursorbind = false
	options.colorcolumn = ""
	options.list = false
	options.spell = false
	M.render(state)
	return state.win
end

---@param state AtlasDiffReviewPanel
function M.close(state)
	if state.win then
		vim.api.nvim_win_close(state.win, true)
	end
end

---@param state AtlasDiffReviewPanel
function M.dispose(state)
	M.close(state)
	vim.api.nvim_del_augroup_by_id(state.group)
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

return M
