---@class PullsFilesTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local diff_blocks = require("atlas.ui.components.diff_blocks")
local changes_block = require("atlas.pulls.ui.components.changes_block")
local table_view = require("atlas.ui.components.table_tree")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.ui.panel.pr.tabs.files.state")

local PADDING_X = 1

---@type { cancel: fun() }[]
local in_flight = {}

---@return PullsProvider|nil
local function get_provider()
	local pulls_state = require("atlas.pulls.state")
	return pulls_state.provider
end

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@param text string
---@return string
local function pad(text)
	return string.rep(" ", PADDING_X) .. tostring(text or "")
end

---@param lines string[]
---@param spans table[]
---@param text string
---@param hl_group string|nil
local function push(lines, spans, text, hl_group)
	table.insert(lines, pad(text))
	if hl_group then
		table.insert(spans, {
			line = #lines - 1,
			start_col = PADDING_X,
			end_col = PADDING_X + #text,
			hl_group = hl_group,
		})
	end
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	cancel_all()
	state.reset()

	local provider = get_provider()
	if not provider then
		return
	end

	local pr_id = tostring(pr.id or "")
	if type(provider.fetch_diff) == "function" then
		state.diff = "loading"
		footer.notify("loading", string.format("Loading changes for #%s...", pr_id))
		track(provider.fetch_diff(pr, opts, function(files, err)
			if err then
				state.diff = err
				footer.notify("error", string.format("Failed to load changes for #%s", pr_id))
			else
				state.diff = files or {}
				footer.notify("success", string.format("Changes loaded for #%s", pr_id), 1200)
			end
			refresh()
		end))
	end
end

--------------------------------------------------------------------------------
-- Diffstat summary
--------------------------------------------------------------------------------

local DIFFSTAT_STATUS_MAP = {
	added = { "+", "AtlasTextPositive" },
	removed = { "-", "AtlasLogError" },
	deleted = { "-", "AtlasLogError" },
	renamed = { "R", "AtlasLogWarn" },
	modified = { "~", "AtlasTextMuted" },
}

---@param entry PullsDiffstatEntry
---@return string
local function diffstat_path(entry)
	local s = tostring(entry.status or ""):lower()
	if s == "renamed" and entry.old_path and entry.old_path ~= "" and entry.path ~= "" then
		return entry.old_path .. " → " .. entry.path
	end
	return entry.path or "(unknown file)"
end

---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_diffstat_summary(width, lines, spans, line_map)
	if not (type(state.diffstat) == "table") then
		return
	end

	local entries = state.diffstat
	if #entries == 0 then
		return
	end

	local total_add, total_del = 0, 0
	for _, entry in ipairs(entries) do
		total_add = total_add + (tonumber(entry.lines_added) or 0)
		total_del = total_del + (tonumber(entry.lines_removed) or 0)
	end

	local collapsed = state.diffstat_collapsed
	local indicator = collapsed and "▸" or "▾"
	local hdr = string.format("%s Files changed (%d)", indicator, #entries)
	local diff_result = diff_blocks.render({ additions = total_add, deletions = total_del })

	if diff_result.text ~= "" then
		local hdr_w = vim.fn.strdisplaywidth(hdr)
		local diff_w = vim.fn.strdisplaywidth(diff_result.text)
		local gap = math.max(1, width - PADDING_X - hdr_w - diff_w)
		local hdr_line = string.rep(" ", PADDING_X) .. hdr .. string.rep(" ", gap) .. diff_result.text
		table.insert(lines, hdr_line)
		local lnum = #lines - 1
		table.insert(spans, { line = lnum, start_col = PADDING_X, end_col = PADDING_X + #hdr, hl_group = "Normal" })
		local diff_byte_start = PADDING_X + #hdr + gap
		for _, hl in ipairs(diff_result.highlights) do
			table.insert(spans, { line = lnum, start_col = diff_byte_start + hl.start_col, end_col = diff_byte_start + hl.end_col, hl_group = hl.hl_group })
		end
	else
		push(lines, spans, hdr, "Normal")
	end
	line_map[#lines] = { type = "diffstat_header" }

	if not collapsed then
		local rows = {}
		for _, entry in ipairs(entries) do
			local s = tostring(entry.status or ""):lower()
			local m = DIFFSTAT_STATUS_MAP[s] or { "~", "AtlasTextMuted" }
			table.insert(rows, {
				marker = m[1],
				marker_hl = m[2],
				path = diffstat_path(entry),
				added = string.format("+%d", tonumber(entry.lines_added) or 0),
				removed = string.format("-%d", tonumber(entry.lines_removed) or 0),
				_entry = entry,
			})
		end

		local row_base = #lines
		for i, row in ipairs(rows) do
			line_map[row_base + i] = { type = "diffstat_row", entry = row._entry }
		end

		local tbl_lines, _, tbl_spans = table_view.render({
			width = width,
			margin = PADDING_X,
			column_gap = 1,
			show_header = false,
			fill = true,
			columns = {
				{ key = "marker", can_grow = false, max_width = 1 },
				{ key = "path", can_grow = true, truncate_from = "start" },
				{ key = "added", can_grow = false, align = "center" },
				{ key = "removed", can_grow = false, align = "center" },
			},
			rows = rows,
			cell_hl = function(row, col)
				if col.key == "marker" then return row.marker_hl end
				if col.key == "path" then return "AtlasTextMuted" end
				if col.key == "added" then return "AtlasTextPositive" end
				if col.key == "removed" then return "AtlasLogError" end
			end,
		})

		utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })
	end

	table.insert(lines, "")
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(20, tonumber(width) or 60)

	render_diffstat_summary(width, lines, spans, line_map)

	if state.diff == nil then
		return lines, spans, line_map
	end

	if state.diff == "loading" then
		push(lines, spans, spinner.with_text("Loading file changes..."), "AtlasTextMuted")
		return lines, spans, line_map
	end

	if type(state.diff) == "string" then
		push(lines, spans, state.diff, "AtlasLogError")
		return lines, spans, line_map
	end

	local files = state.diff
	if #files == 0 then
		push(lines, spans, "No diff available.", nil)
		return lines, spans, line_map
	end

	local cb_lines, cb_spans, cb_map = changes_block.render(files, {
		max_width = max_width,
		padding_x = PADDING_X,
		collapsed_hunks = state.collapsed_hunks,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = cb_lines, highlights = cb_spans })
	for lnum, entry in pairs(cb_map or {}) do
		line_map[offset + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _pr PullRequest
---@param entry table
---@return boolean|nil
function M.on_enter(_pr, entry)
	if entry.type == "diffstat_header" then
		state.diffstat_collapsed = not state.diffstat_collapsed
		return true
	end
	if entry.kind == "hunk_header" and entry.hunk_key then
		state.collapsed_hunks[entry.hunk_key] = not state.collapsed_hunks[entry.hunk_key]
		return true
	end
end

---@param entry table|nil
function M.toggle_hunk(entry)
	if entry and entry.type == "diffstat_header" then
		state.diffstat_collapsed = not state.diffstat_collapsed
	elseif entry and entry.kind == "hunk_header" and entry.hunk_key then
		state.collapsed_hunks[entry.hunk_key] = not state.collapsed_hunks[entry.hunk_key]
	end
end

---@return boolean
function M.toggle_all_hunks()
	if type(state.diff) ~= "table" then
		return false
	end

	---@type string[]
	local keys = {}
	for _, file in ipairs(state.diff) do
		for _, hunk in ipairs(file.hunks or {}) do
			table.insert(keys, changes_block.hunk_key(file, hunk))
		end
	end

	if #keys == 0 then
		return false
	end

	local should_expand = false
	for _, k in ipairs(keys) do
		if state.collapsed_hunks[k] == true then
			should_expand = true
			break
		end
	end

	state.collapsed_hunks = {}
	if should_expand then
		return true
	end

	for _, k in ipairs(keys) do
		state.collapsed_hunks[k] = true
	end
	return true
end

---@param direction "next"|"prev"
function M.jump_hunk(direction)
	local layout = require("atlas.ui.layout")
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local win = layout.win_id("detail")
	local buf = layout.buf_id("detail")
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local line = vim.api.nvim_win_get_cursor(win)[1]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "next" and 1 or -1
	local bound = direction == "next" and max_line or 1
	local line_map = panel_state.line_map or {}

	for lnum = line + step, bound, step do
		local entry = line_map[lnum]
		if entry and entry.kind == "hunk_header" then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			return
		end
	end
end

local keymaps = require("atlas.pulls.ui.panel.pr.tabs.files.keymaps")
function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	cancel_all()
end

return M
