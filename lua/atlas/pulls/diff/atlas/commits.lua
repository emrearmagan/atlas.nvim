local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_native_commits")

---@param session AtlasDiffSession
function M.render(session)
	local buf = session.viewer_state.commits_panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local win = session.viewer_state.commits_panel.win
	local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)
		or session.viewer_state.explorer.width
	local lines, highlights = { "" }, {}
	local icon, icon_hl = icons.pulls("commit")
	session.viewer_state.commit_items = {}

	if #session.commits == 0 then
		table.insert(lines, "No commits")
		table.insert(highlights, { 1, 0, #lines[2], "AtlasTextMuted" })
	else
		for _, commit in ipairs(session.commits) do
			local hash = tostring(commit.short_hash or commit.hash or ""):sub(1, 8)
			local message = tostring(commit.message or ""):gsub("\r\n", "\n"):match("[^\n]+") or ""
			local prefix = string.format("%s %s ", icon, hash)
			local text = prefix .. utils.truncate(message, math.max(1, width - vim.fn.strdisplaywidth(prefix)))
			table.insert(lines, text)
			session.viewer_state.commit_items[#lines] = commit
			local icon_start = 0
			local hash_start = icon_start + #icon + 1
			table.insert(highlights, { #lines - 1, icon_start, icon_start + #icon, icon_hl })
			table.insert(highlights, { #lines - 1, hash_start, hash_start + #hash, "AtlasTextMuted" })
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
		virt_text = { { string.format("Commits (%d)", #session.commits), "AtlasLogInfo" } },
		virt_text_pos = "overlay",
	})
	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, namespace, highlight[1], highlight[2], {
			end_col = highlight[3],
			hl_group = highlight[4],
		})
	end
	if win and vim.api.nvim_win_is_valid(win) and #session.commits > 0 then
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] == 1 then
			vim.api.nvim_win_set_cursor(win, { 2, 0 })
		end
	end
end

---@param session AtlasDiffSession
function M.show_details(session)
	if vim.api.nvim_get_current_buf() ~= session.viewer_state.commits_panel.buf then
		return
	end
	local commit = session.viewer_state.commit_items[vim.api.nvim_win_get_cursor(0)[1]]
	if not commit then
		return
	end
	local lines = vim.split(tostring(commit.message or ""), "\n", { plain = true })
	table.insert(lines, "")
	table.insert(lines, "Commit: " .. tostring(commit.hash or commit.short_hash or ""))
	local author = tostring(commit.author_nickname or "")
	if author == "" then
		author = tostring(commit.author_name or "Unknown")
	end
	table.insert(lines, "Author: " .. author)
	table.insert(lines, "Date: " .. tostring(commit.date or ""))
	local width = math.max(1, math.min(100, vim.o.columns - 4))
	vim.lsp.util.open_floating_preview(lines, "markdown", {
		border = "rounded",
		focusable = false,
		max_width = width,
		wrap_at = width,
		title = string.format(" Commit %s ", tostring(commit.short_hash or commit.hash or ""):sub(1, 8)),
	})
end

return M
