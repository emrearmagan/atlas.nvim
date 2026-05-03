local M = {}

local table_tree = require("atlas.ui.components.table_tree")
local pulls_helper = require("atlas.pulls.ui.main.helper")

local NS = vim.api.nvim_create_namespace("atlas.pulls.create_pr.meta")

---@param state CreatePRState
function M.render_meta(state)
	local buf = state.layout.meta_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local repo = tostring(state.fields.repo_slug or "")
	local head = tostring(state.fields.head or "")
	local base = tostring(state.fields.base or "")
	local draft = state.fields.draft == true

	local branch_value = string.format("%s → %s", head, base)
	local chip_label = draft and " DRAFT " or " READY "
	local chip_hl = draft and pulls_helper.pr_state_hl("draft") or pulls_helper.pr_state_hl("open")

	local rows = {
		{
			k1 = "Repo:",
			v1 = repo,
			v1_hl = pulls_helper.repo_hl(repo),
			k2 = "Branch:",
			v2 = branch_value,
			v2_hl = "AtlasTextMuted",
		},
	}

	local lines, _, spans = table_tree.render({
		columns = {
			{ key = "k1", name = "", can_grow = false },
			{ key = "v1", name = "", can_grow = true },
			{ key = "k2", name = "", can_grow = false },
			{ key = "v2", name = "", can_grow = true, grow_last = true },
		},
		rows = rows,
		width = state.content_width,
		margin = 0,
		show_header = false,
		column_gap = 2,
		fill = true,
		cell_hl = function(row, col)
			if col.key == "k1" or col.key == "k2" then
				local label = col.key == "k1" and row.k1 or row.k2
				if label == "" then
					return nil
				end
				return {
					{ start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" },
				}
			end

			if col.key == "v1" and row.v1 ~= "" then
				return {
					{ start_col = 0, end_col = #row.v1, hl_group = row.v1_hl },
				}
			end

			if col.key == "v2" and row.v2 ~= "" then
				return {
					{ start_col = 0, end_col = #row.v2, hl_group = row.v2_hl },
				}
			end

			return nil
		end,
	})

	local chip_line_idx = #lines
	table.insert(lines, chip_label)

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

	for _, span in ipairs(spans or {}) do
		pcall(vim.api.nvim_buf_set_extmark, buf, NS, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	pcall(vim.api.nvim_buf_set_extmark, buf, NS, chip_line_idx, 0, {
		end_col = #chip_label,
		hl_group = chip_hl,
	})
end

return M
