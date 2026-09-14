local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local diff = require("atlas.ui.components.diff_hunks")
local keymaps = require("atlas.core.keymaps")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local state = require("atlas.pulls.ui.detail.tabs.review.state")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1

---@param tasks PullsComment[]
---@return string
local function task_heading(tasks)
	local label = vim.trim(tostring(tasks[1] and tasks[1].task_label or "Task"))
	if label == "" then
		label = "Task"
	end
	return label:sub(-1):lower() == "s" and label or (label .. "s")
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param task PullsComment
---@param width integer
local function emit_task(lines, spans, line_map, task, width)
	local task_lines, task_spans, task_map = review_threads.render_task_compact(
		{ comment = task, children = {} },
		width,
		{
			padding_x = PADDING_X,
			show_task_label = false,
		}
	)
	local offset = #lines
	utils.append_block(lines, spans, { lines = task_lines, highlights = task_spans })
	for line, entry in pairs(task_map) do
		line_map[offset + line] = entry
	end
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param nodes AtlasReviewThreadNode[]
---@param width integer
local function emit_thread_box(lines, spans, line_map, nodes, width)
	local inner = math.max(1, width - 4)
	local toggle_keys = keymaps.resolve("pulls.review.diff.toggle_resolved")
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local thread_lines, thread_spans, thread_map = review_threads.render(nodes, inner, {
		expanded = function(root)
			return state.is_thread_expanded(root)
		end,
		padding_x = 0,
		toggle_resolved_key = toggle_keys and table.concat(toggle_keys, " / ") or nil,
		reaction_options = comments and comments.reaction_options,
	})
	local mark_line = #lines
	local result = box.render({ { lines = thread_lines, spans = thread_spans, line_map = thread_map } }, {
		width = width,
		padding_x = 0,
		line_map = line_map,
		line_offset = mark_line,
	})
	utils.append_block(lines, spans, { lines = result.lines, highlights = result.highlights })
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param width integer
---@param thread AtlasReviewThreadNode
local function emit_thread(lines, spans, line_map, width, thread)
	local comment = thread.comment
	local position = comment.file or comment.inline
	if position then
		local hunk = comment.inline and comment.outdated ~= true and comment.hunk or nil
		local file = { path = position.path, status = "modified", hunks = hunk and { hunk } or {} }
		local code_lines, code_spans, code_map = diff.hunks({ file }, {
			max_width = width,
			padding_x = PADDING_X,
			show_line_numbers = false,
		})
		local offset = #lines
		utils.append_block(lines, spans, { lines = code_lines, highlights = code_spans })
		for line, entry in pairs(code_map) do
			line_map[offset + line] = entry
		end
	end
	emit_thread_box(lines, spans, line_map, { thread }, width)
end

---@param width integer
---@param comments PullsComment[]|"loading"|string|nil
---@param tasks PullsComment[]|"loading"|string|nil
---@return string[], table[], table<integer, table>
function M.render(width, comments, tasks)
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(1, width)

	if tasks == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading tasks..."), "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "string" then
		utils.push(lines, spans, tasks, "AtlasLogError", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "table" and #tasks > 0 then
		---@cast tasks PullsComment[]
		local sorted_tasks = vim.list_extend({}, tasks)
		table.sort(sorted_tasks, function(left, right)
			local left_date = tostring(left.created_on or "")
			local right_date = tostring(right.created_on or "")
			return left_date == right_date and tostring(left.id) < tostring(right.id) or left_date < right_date
		end)
		utils.push(lines, spans, task_heading(sorted_tasks), "AtlasColumnHeader", PADDING_X)
		for _, task in ipairs(sorted_tasks) do
			emit_task(lines, spans, line_map, task, max_width)
		end
		table.insert(lines, "")
	end

	if comments == nil then
		return lines, spans, line_map
	end

	if comments == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading comments..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(comments) == "string" then
		utils.push(lines, spans, comments, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	---@cast comments PullsComment[]
	if #comments == 0 then
		utils.push(lines, spans, "No comments yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local roots = review_threads.group_comments(comments, type(tasks) == "table" and tasks or nil)
	for _, thread in ipairs(roots) do
		emit_thread(lines, spans, line_map, max_width, thread)
		table.insert(lines, "")
	end

	return lines, spans, line_map
end

return M
