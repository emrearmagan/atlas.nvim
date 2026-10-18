local keymap_resolver = require("atlas.core.keymaps")
local keymaps = require("atlas.pulls.diff.ui.review_panel.keymaps")
local renderer = require("atlas.pulls.diff.ui.review_panel.renderer")

---@class AtlasDiffReviewPanel
---@field session AtlasDiffSession
---@field options AtlasPullsDiffReviewPanelConfig
---@field buf integer
---@field win integer|nil
---@field group integer
---@field expanded table<string, boolean>
---@field line_map table<integer, AtlasDiffReviewPanelRow>
---@field filter AtlasDiffReviewPanelFilter
local ReviewPanel = {}
ReviewPanel.__index = ReviewPanel

local namespace = vim.api.nvim_create_namespace("atlas.diff.review_panel")
local filter_labels = { all = "All", unresolved = "Unresolved", mine = "Mine" }

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keys = keymap_resolver.resolve(action)
	return keys and #keys > 0 and table.concat(keys, " / ") or nil
end

function ReviewPanel:render()
	if not self.win then
		return
	end
	local previous = self.expanded
	self.expanded = {}
	local function expanded(key)
		self.expanded[key] = previous[key] == true
		return self.expanded[key]
	end

	local lines, spans, line_map = renderer.render(self.session, self.filter, vim.api.nvim_win_get_width(self.win), {
		reply = key_label("pulls.review.add_comment"),
		add_task = key_label("pulls.review.add_task"),
		edit = key_label("ui.comments.edit"),
		delete = key_label("ui.delete"),
		toggle_resolved = key_label("pulls.review.toggle_resolved"),
	}, expanded)

	local filter_key = key_label("pulls.review.panel.cycle_filter")
	vim.wo[self.win].winbar = " Review%="
		.. filter_labels[self.filter]
		.. (filter_key and "  %#AtlasTextMuted#" .. filter_key:gsub("%%", "%%%%") .. " filter" or "")
		.. " "

	self.line_map = line_map
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.bo[self.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(self.buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffReviewPanelConfig
---@param callbacks { on_select: fun(entry: AtlasDiffReviewPanelRow, focus: boolean), on_action: fun(id: AtlasReviewActionId, target: { comment?: PullsComment, note?: AtlasNote, review_entry?: PullsReviewHistoryEntry, pending?: boolean }), on_resize: fun() }
---@return AtlasDiffReviewPanel
function ReviewPanel.new(session, options, callbacks)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, string.format("Review [%d]", vim.api.nvim_get_current_tabpage()))
	local state = setmetatable({
		session = session,
		options = options,
		buf = buf,
		group = vim.api.nvim_create_augroup("AtlasDiffReviewPanel" .. buf, { clear = true }),
		expanded = {},
		line_map = {},
		filter = "all",
	}, ReviewPanel)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas-ui.review"
	vim.bo[buf].modifiable = false

	keymaps.setup(state, callbacks)

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
				state:render()
				callbacks.on_resize()
			end
		end,
	})
	return state
end

---@param state AtlasDiffReviewPanel
---@return integer
local function height(state)
	local configured = math.max(4, math.floor(state.options.height))
	return math.min(configured, math.max(4, vim.o.lines - 8))
end

function ReviewPanel:resize()
	if self.win then
		vim.api.nvim_win_set_height(self.win, height(self))
		self:render()
	end
end

---@return integer
function ReviewPanel:open()
	if self.win then
		return self.win
	end
	self.win = vim.api.nvim_open_win(self.buf, false, {
		split = "below",
		win = -1,
		height = height(self),
	})
	local options = vim.wo[self.win][0]
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
	self:render()
	return self.win
end

function ReviewPanel:close()
	if self.win then
		vim.api.nvim_win_close(self.win, true)
	end
end

function ReviewPanel:dispose()
	self:close()
	vim.api.nvim_del_augroup_by_id(self.group)
	if vim.api.nvim_buf_is_valid(self.buf) then
		vim.api.nvim_buf_delete(self.buf, { force = true })
	end
end

return ReviewPanel
