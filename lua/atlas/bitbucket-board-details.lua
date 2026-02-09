---@class Bitbucket.Details
local M = {}

local api = vim.api
local state = require("atlas.bitbucket-board-state")

function M.show_help_popup()
	local help_content = {
		{ section = "Navigation & View" },
		{ k = "<Tab> / <S-Tab>", d = "Next/Previous view" },
		{ k = "j/k", d = "Navigate between PRs" },
		{ k = "za", d = "Expand/Collapse repo" },
		{ k = "H", d = "Show Help" },
		{ k = "q", d = "Close Board" },
		{ k = "r", d = "Refresh current view" },

		{ section = "PR Actions" },
		{ k = "<CR> / K", d = "Show PR Details" },
		{ k = "a", d = "PR actions (menu)" },
		{ k = "gx", d = "Open PR in Browser" },
	}

	local lines = { " Bitbucket Keybindings", " " .. ("━"):rep(50) }
	local hls = {}

	table.insert(hls, { row = 0, col = 1, end_col = -1, hl = "Title" })
	table.insert(hls, { row = 1, col = 0, end_col = -1, hl = "Comment" })

	local row = 2
	for _, item in ipairs(help_content) do
		if item.section then
			table.insert(lines, "")
			table.insert(lines, " " .. item.section)
			table.insert(hls, { row = row + 1, col = 1, end_col = -1, hl = "Label" })
			row = row + 2
		else
			local line = ("   %-18s %s"):format(item.k, item.d)
			table.insert(lines, line)
			table.insert(hls, { row = row, col = 3, end_col = 3 + #item.k, hl = "Special" })
			row = row + 1
		end
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local width = 60
	local height = #lines
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " Help ",
		title_pos = "center",
	})

	for _, hl in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(buf, -1, hl.hl, hl.row, hl.col, hl.end_col)
	end

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, nowait = true })
end

---Format time ago
---@param timestamp string
---@return string
local function format_time_ago(timestamp)
	if not timestamp then
		return "N/A"
	end

	local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not year then
		return "N/A"
	end

	local time = os.time({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
	})

	local diff = os.time() - time
	local days = math.floor(diff / 86400)
	local hours = math.floor((diff % 86400) / 3600)
	local mins = math.floor((diff % 3600) / 60)

	if days > 0 then
		return days .. "d ago"
	elseif hours > 0 then
		return hours .. "h ago"
	else
		return mins .. "m ago"
	end
end

---Get build status icon and highlight
local function get_build_display(status)
	if not status then
		return "N/A", "Comment"
	elseif status == "SUCCESSFUL" then
		return "✓ Success", "BitbucketBuildSuccess"
	elseif status == "FAILED" then
		return "✗ Failed", "BitbucketBuildFailed"
	elseif status == "INPROGRESS" then
		return "◐ In Progress", "BitbucketBuildInProgress"
	else
		return status, "Comment"
	end
end

---Show comprehensive PR details view
---@param pr table
function M.show_pr_full_details(pr)
	if not pr then
		vim.notify("No PR data available", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading PR details...")

	local bb_api = require("atlas.bitbucket-api.api")
	bb_api.get_pull_request(pr.workspace, pr.repo, pr.id, function(pr_details, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching PR details: " .. err, vim.log.levels.ERROR)
				return
			end

			local lines = {}
			local highlights = {}
			
			local title_line = #lines
			table.insert(lines, string.format("PR #%d", pr.id or 0))
			table.insert(highlights, { line = title_line, col_start = 0, col_end = -1, hl_group = "Title" })
			
			table.insert(lines, pr.title or "Untitled")
			table.insert(lines, "")
			
			local status_icon = pr.status == "OPEN" and "●" or "○"
			local status_line = string.format("%s %s", status_icon, pr.status or "UNKNOWN")
			if pr.is_draft then
				status_line = status_line .. " (Draft)"
			end
			local status_line_num = #lines
			table.insert(lines, status_line)
			local status_hl = pr.status == "OPEN" and "DiagnosticOk" or "Comment"
			table.insert(highlights, { line = status_line_num, col_start = 0, col_end = -1, hl_group = status_hl })
			
			table.insert(lines, "")
			table.insert(lines, ("─"):rep(80))
			table.insert(lines, "")
			
			local author_header = #lines
			table.insert(lines, "Author")
			table.insert(highlights, { line = author_header, col_start = 0, col_end = -1, hl_group = "Function" })
			table.insert(lines, string.format("  %s", pr.assignee or "Unknown"))
			table.insert(lines, "")
			
			local branches_header = #lines
			table.insert(lines, "Branches")
			table.insert(highlights, { line = branches_header, col_start = 0, col_end = -1, hl_group = "Function" })
			table.insert(lines, string.format("  %s → %s", pr.source_branch or "unknown", pr.destination_branch or "unknown"))
			table.insert(lines, "")
			
			local timeline_header = #lines
			table.insert(lines, "Timeline")
			table.insert(highlights, { line = timeline_header, col_start = 0, col_end = -1, hl_group = "Function" })
			table.insert(lines, string.format("  Created  %s", format_time_ago(pr.created_on)))
			table.insert(lines, string.format("  Updated  %s", format_time_ago(pr.updated_on)))
			table.insert(lines, "")
			
			if pr_details and pr_details.participants and #pr_details.participants > 0 then
				local reviewers_header = #lines
				table.insert(lines, string.format("Reviewers (%d)", #pr_details.participants))
				table.insert(highlights, { line = reviewers_header, col_start = 0, col_end = -1, hl_group = "Function" })
				
				local approved = {}
				local changes_requested = {}
				local pending = {}
				
				for _, p in ipairs(pr_details.participants) do
					local name = (p.user and p.user.display_name) or "Unknown"
					if p.approved then
						table.insert(approved, name)
					elseif p.state == "changes_requested" then
						table.insert(changes_requested, name)
					else
						table.insert(pending, name)
					end
				end
				
				if #approved > 0 then
					local approved_line = #lines
					table.insert(lines, "  ✓ Approved")
					table.insert(highlights, { line = approved_line, col_start = 2, col_end = 3, hl_group = "DiagnosticOk" })
					for _, name in ipairs(approved) do
						table.insert(lines, string.format("    • %s", name))
					end
				end
				
				if #changes_requested > 0 then
					local changes_line = #lines
					table.insert(lines, "  ✗ Changes requested")
					table.insert(highlights, { line = changes_line, col_start = 2, col_end = 3, hl_group = "DiagnosticError" })
					for _, name in ipairs(changes_requested) do
						table.insert(lines, string.format("    • %s", name))
					end
				end
				
				if #pending > 0 then
					local pending_line = #lines
					table.insert(lines, "  ○ Pending")
					table.insert(highlights, { line = pending_line, col_start = 2, col_end = 3, hl_group = "Comment" })
					for _, name in ipairs(pending) do
						table.insert(lines, string.format("    • %s", name))
					end
				end
				table.insert(lines, "")
			end
			
			local activity_header = #lines
			table.insert(lines, "Activity")
			table.insert(highlights, { line = activity_header, col_start = 0, col_end = -1, hl_group = "Function" })
			table.insert(lines, string.format("  Comments: %d", pr.comment_count or 0))
			table.insert(lines, string.format("  Tasks:    %d", pr.task_count or 0))
			if pr.commit_hash then
				table.insert(lines, string.format("  Commit:   %s", pr.commit_hash))
			end
			table.insert(lines, "")
			
			if pr.build_status then
				local build_icon = pr.build_status == "SUCCESSFUL" and "✓" or (pr.build_status == "FAILED" and "✗" or "◐")
				local build_line = #lines
				table.insert(lines, string.format("Build  %s %s", build_icon, pr.build_status))
				local build_hl = pr.build_status == "SUCCESSFUL" and "DiagnosticOk" or (pr.build_status == "FAILED" and "DiagnosticError" or "DiagnosticWarn")
				table.insert(highlights, { line = build_line, col_start = 7, col_end = 8, hl_group = build_hl })
				table.insert(lines, "")
			end
			
			if pr.description and pr.description ~= "" then
				table.insert(lines, ("─"):rep(80))
				table.insert(lines, "")
				local desc_header = #lines
				table.insert(lines, "Description")
				table.insert(highlights, { line = desc_header, col_start = 0, col_end = -1, hl_group = "Function" })
				table.insert(lines, "")
				for line in pr.description:gmatch("[^\r\n]+") do
					table.insert(lines, line)
				end
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			
			for _, hl in ipairs(highlights) do
				api.nvim_buf_add_highlight(buf, -1, hl.hl_group, hl.line, hl.col_start, hl.col_end)
			end
			
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(100, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " PR Details ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "gx", function()
				if pr.url then
					vim.ui.open(pr.url)
				end
			end, { buffer = buf, nowait = true })
		end)
	end)
end

---Show PR details popup (Jira-style)
---@param pr table The PR object with all fields
function M.show_pr_details(pr)
	if not pr then
		vim.notify("No PR data available", vim.log.levels.WARN)
		return
	end

	-- Get build status display
	local build_text, build_hl = get_build_display(pr.build_status)

	-- Build the content lines (Jira-style)
	local lines = {
		" #" .. (pr.id or "?") .. ": " .. (pr.title or "Untitled"),
		" " .. ("━"):rep(math.min(60, 4 + #(pr.title or "Untitled"))),
		(" Author:   %s"):format(pr.author and pr.author.display_name or "Unknown"),
		(" Repo:     %s/%s"):format(pr.workspace or "", pr.repo or ""),
		(" Updated:  %s"):format(format_time_ago(pr.updated_on)),
	}

	local hls = {}
	local next_row = 0

	-- Header highlight
	table.insert(hls, { row = next_row, col = 1, end_col = 2 + #tostring(pr.id or "?"), hl = "Title" })
	next_row = next_row + 1
	table.insert(hls, { row = next_row, col = 0, end_col = -1, hl = "Comment" })
	next_row = next_row + 1

	-- Author
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketAuthor" })
	next_row = next_row + 1

	-- Repo
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketRepo" })
	next_row = next_row + 1

	-- Updated
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketTime" })
	next_row = next_row + 1

	-- Branches
	table.insert(lines, (" Source:   %s"):format(pr.source_branch or "N/A"))
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketBranch" })
	next_row = next_row + 1

	table.insert(lines, (" Target:   %s"):format(pr.destination_branch or "N/A"))
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketBranch" })
	next_row = next_row + 1

	-- Commit
	if pr.commit_hash then
		table.insert(lines, (" Commit:   %s"):format(pr.commit_hash))
		table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
		table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "Number" })
		next_row = next_row + 1
	end

	-- Metrics
	if pr.comment_count and pr.comment_count > 0 then
		table.insert(lines, (" Comments: %s 󰍩"):format(pr.comment_count))
		table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
		table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketComments" })
		next_row = next_row + 1
	end

	if pr.task_count and pr.task_count > 0 then
		table.insert(lines, (" Tasks:    %s ☑"):format(pr.task_count))
		table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
		table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "Number" })
		next_row = next_row + 1
	end

	if pr.approvals or pr.total_reviewers then
		table.insert(lines, (" Approvals: %s/%s ✓"):format(pr.approvals or 0, pr.total_reviewers or 0))
		table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
		table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketApproved" })
		next_row = next_row + 1
	end

	if pr.needs_work and pr.needs_work > 0 then
		table.insert(lines, (" Needs Work: %s ●"):format(pr.needs_work))
		table.insert(hls, { row = next_row, col = 1, end_col = 12, hl = "Label" })
		table.insert(hls, { row = next_row, col = 13, end_col = -1, hl = "BitbucketNeedsWork" })
		next_row = next_row + 1
	end

	-- Build status
	table.insert(lines, (" Build:    %s"):format(build_text))
	table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
	table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = build_hl })
	next_row = next_row + 1

	-- Draft
	if pr.is_draft then
		table.insert(lines, " Draft:    Yes")
		table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
		table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "WarningMsg" })
		next_row = next_row + 1
	end

	-- Close source branch
	local close_branch = pr.close_source_branch and "Yes" or "No"
	table.insert(lines, (" Close Branch: %s"):format(close_branch))
	table.insert(hls, { row = next_row, col = 1, end_col = 14, hl = "Label" })
	table.insert(hls, { row = next_row, col = 15, end_col = -1, hl = pr.close_source_branch and "String" or "Comment" })
	next_row = next_row + 1

	-- Description
	if pr.description and pr.description ~= "" then
		table.insert(lines, "")
		next_row = next_row + 1
		table.insert(lines, " Description:")
		table.insert(hls, { row = next_row, col = 1, end_col = -1, hl = "Label" })
		next_row = next_row + 1

		local desc_lines = vim.split(pr.description, "\n")
		for i, line in ipairs(desc_lines) do
			if i > 10 then
				table.insert(lines, " ...")
				next_row = next_row + 1
				break
			end
			local truncated = line
			if #line > 80 then
				truncated = line:sub(1, 77) .. "..."
			end
			table.insert(lines, " " .. truncated)
			table.insert(hls, { row = next_row, col = 1, end_col = -1, hl = "Comment" })
			next_row = next_row + 1
		end
	end

	-- Create buffer
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_set_option_value("modifiable", false, { buf = buf })
	api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

	-- Apply highlights
	for _, h in ipairs(hls) do
		local end_col = h.end_col
		if end_col == -1 then
			end_col = #lines[h.row + 1]
		end
		api.nvim_buf_set_extmark(buf, state.ns, h.row, h.col, {
			end_col = end_col,
			hl_group = h.hl,
		})
	end

	-- Calculate width
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = width + 2
	local height = #lines

	-- Create window (near cursor, like Jira)
	local win = api.nvim_open_win(buf, false, {
		relative = "cursor",
		width = width,
		height = height,
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
		focusable = false,
	})

	-- Auto-close on cursor move
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
		buffer = state.buf,
		once = true,
		callback = function()
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
		end,
	})
end

---Show PR comments in a scrollable buffer
---@param pr table
function M.show_pr_comments_view(pr)
	if not pr or not pr.workspace or not pr.repo or not pr.id then
		vim.notify("Invalid PR data", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading comments and tasks...")

	local bb_api = require("atlas.bitbucket-api.api")
	
	bb_api.get_pr_tasks(pr.workspace, pr.repo, pr.id, function(tasks_result, tasks_err)
		local comment_to_tasks = {}
		if not tasks_err and tasks_result and tasks_result.values then
			for _, task in ipairs(tasks_result.values) do
				if task.comment and task.comment.id then
					if not comment_to_tasks[task.comment.id] then
						comment_to_tasks[task.comment.id] = {}
					end
					table.insert(comment_to_tasks[task.comment.id], task)
				end
			end
		end
		
		bb_api.get_pr_comments(pr.workspace, pr.repo, pr.id, function(result, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching comments: " .. err, vim.log.levels.ERROR)
				return
			end

			local comments = (result and result.values) or {}
			if #comments == 0 then
				vim.notify("No comments on this PR", vim.log.levels.INFO)
				return
			end

			local function hash_string_to_color(str)
				local hash = 0
				for i = 1, #str do
					hash = hash + string.byte(str, i)
				end
				local colors = {
					"DiagnosticInfo",
					"DiagnosticHint",
					"DiagnosticOk",
					"String",
					"Function",
					"Identifier",
					"Type",
					"Special"
				}
				return colors[(hash % #colors) + 1]
			end

			local threads = {}
			local root_comments = {}
			local lines = {}
			local highlights = {}
			local line_to_comment = {}
			
			for _, comment in ipairs(comments) do
				local parent_id = comment.parent and comment.parent.id
				if parent_id then
					if not threads[parent_id] then
						threads[parent_id] = {}
					end
					table.insert(threads[parent_id], comment)
				else
					table.insert(root_comments, comment)
				end
			end

			local function render_comment(comment, indent, is_last_reply)
				local author = (comment.user and comment.user.display_name) or "Unknown"
				local created = format_time_ago(comment.created_on)
				local content = (comment.content and comment.content.raw) or (comment.deleted and "[deleted]" or "[no content]")
				local is_inline = comment.inline and comment.inline.path
				local tasks = comment_to_tasks[comment.id] or {}
				
				local comment_start_line = #lines
				local prefix = indent > 0 and (is_last_reply and "  └─ " or "  ├─ ") or ""
				
				if indent == 0 then
					if is_inline then
						local file_path = comment.inline.path or ""
						local filename = file_path:match("([^/]+)$") or file_path
						local line_num = comment.inline.to
						if line_num and type(line_num) == "number" then
							table.insert(lines, string.format("%s:%d", filename, line_num))
						else
							table.insert(lines, filename)
						end
						line_to_comment[#lines - 1] = comment
						table.insert(highlights, {
							line = #lines - 1,
							col_start = 0,
							col_end = #lines[#lines],
							hl_group = "Comment"
						})
					else
						table.insert(lines, "General comment")
						line_to_comment[#lines - 1] = comment
						table.insert(highlights, {
							line = #lines - 1,
							col_start = 0,
							col_end = #lines[#lines],
							hl_group = "Comment"
						})
					end
				end
				
				local author_line = string.format("%s%s • %s", prefix, author, created)
				table.insert(lines, author_line)
				line_to_comment[#lines - 1] = comment
				table.insert(highlights, {
					line = #lines - 1,
					col_start = #prefix,
					col_end = #prefix + #author,
					hl_group = hash_string_to_color(author)
				})
				
				local content_indent = indent > 0 and (is_last_reply and "       " or "  │    ") or "  "
				for line in content:gmatch("[^\r\n]+") do
					table.insert(lines, content_indent .. line)
					line_to_comment[#lines - 1] = comment
				end
				
				if #tasks > 0 then
					table.insert(lines, "")
					for i, task in ipairs(tasks) do
						local task_content = (task.content and task.content.raw) or ""
						local task_state = task.state == "RESOLVED" and "✓" or "○"
						local task_indent = content_indent
						table.insert(lines, string.format("%s%s Task: %s", task_indent, task_state, task_content))
						line_to_comment[#lines - 1] = comment
					end
				end
				
				local replies = threads[comment.id] or {}
				if #replies > 0 then
					table.insert(lines, "")
					for j, reply in ipairs(replies) do
						render_comment(reply, indent + 1, j == #replies)
					end
				end
			end
			
			for i, comment in ipairs(root_comments) do
				render_comment(comment, 0, false)
				
				if i < #root_comments then
					table.insert(lines, "")
					table.insert(lines, ("─"):rep(80))
					table.insert(lines, "")
				end
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			
			for _, hl in ipairs(highlights) do
				api.nvim_buf_add_highlight(buf, -1, hl.hl_group, hl.line, hl.col_start, hl.col_end)
			end
			
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(120, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " PR Comments ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "gx", function()
				local cursor = api.nvim_win_get_cursor(win)
				local line_num = cursor[1] - 1
				local comment = line_to_comment[line_num]
				if comment and comment.links and comment.links.html and comment.links.html.href then
					vim.ui.open(comment.links.html.href)
				else
					vim.notify("No URL for this comment", vim.log.levels.WARN)
				end
			end, { buffer = buf, nowait = true })
		end)
	end)
	end)
end

---Show PR commits in a scrollable buffer
---@param pr table
function M.show_pr_commits_view(pr)
	if not pr or not pr.workspace or not pr.repo or not pr.id then
		vim.notify("Invalid PR data", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading commits...")

	local bb_api = require("atlas.bitbucket-api.api")
	bb_api.get_pr_commits(pr.workspace, pr.repo, pr.id, function(result, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching commits: " .. err, vim.log.levels.ERROR)
				return
			end

			local commits = (result and result.values) or {}
			if #commits == 0 then
				vim.notify("No commits in this PR", vim.log.levels.INFO)
				return
			end

			local lines = { " Commits for PR #" .. pr.id, " " .. ("━"):rep(50), "" }
			for _, commit in ipairs(commits) do
				local hash = (commit.hash and commit.hash:sub(1, 7)) or "unknown"
				local author = (commit.author and commit.author.user and commit.author.user.display_name) or "Unknown"
				local date = format_time_ago(commit.date)
				local message = (commit.message or ""):match("^[^\r\n]+") or ""
				
				table.insert(lines, string.format("%s  %s  %s", hash, author, date))
				table.insert(lines, "  " .. message)
				table.insert(lines, "")
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(100, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " PR Commits ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
		end)
	end)
end

---Show PR tasks in a scrollable buffer
---@param pr table
function M.show_pr_tasks_view(pr)
	if not pr or not pr.workspace or not pr.repo or not pr.id then
		vim.notify("Invalid PR data", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading tasks...")

	local bb_api = require("atlas.bitbucket-api.api")
	bb_api.get_pr_tasks(pr.workspace, pr.repo, pr.id, function(result, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching tasks: " .. err, vim.log.levels.ERROR)
				return
			end

			local tasks = (result and result.values) or {}
			if #tasks == 0 then
				vim.notify("No tasks on this PR", vim.log.levels.INFO)
				return
			end

			local lines = { " Tasks for PR #" .. pr.id, " " .. ("━"):rep(50), "" }
			for i, task in ipairs(tasks) do
				local state = task.state or "UNRESOLVED"
				local content = (task.content and task.content.raw) or ""
				local creator = (task.creator and task.creator.display_name) or "Unknown"
				local created = format_time_ago(task.created_on)
				
				local status_icon = state == "RESOLVED" and "✓" or "○"
				table.insert(lines, string.format("%s Task #%d by %s (%s):", status_icon, i, creator, created))
				table.insert(lines, "  " .. content)
				table.insert(lines, "")
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(100, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " PR Tasks ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
		end)
	end)
end

---Show PR changed files in a scrollable buffer
---@param pr table
function M.show_pr_files_view(pr)
	if not pr or not pr.workspace or not pr.repo or not pr.id then
		vim.notify("Invalid PR data", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading changed files...")

	local bb_api = require("atlas.bitbucket-api.api")
	bb_api.get_pr_commits(pr.workspace, pr.repo, pr.id, function(result, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching commits: " .. err, vim.log.levels.ERROR)
				return
			end

			local commits = (result and result.values) or {}
			if #commits == 0 then
				vim.notify("No commits in this PR", vim.log.levels.INFO)
				return
			end

			local files_map = {}
			for _, commit in ipairs(commits) do
				if commit.files then
					for _, file in ipairs(commit.files) do
						local path = file.path or file.file or "unknown"
						if not files_map[path] then
							files_map[path] = {
								path = path,
								type = file.type or "modified"
							}
						end
					end
				end
			end

			local files = {}
			for _, file in pairs(files_map) do
				table.insert(files, file)
			end
			table.sort(files, function(a, b) return a.path < b.path end)

			if #files == 0 then
				vim.notify("No file information available", vim.log.levels.INFO)
				return
			end

			local lines = { " Changed Files for PR #" .. pr.id, " " .. ("━"):rep(50), "" }
			for _, file in ipairs(files) do
				table.insert(lines, string.format("%-10s  %s", file.type, file.path))
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(120, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " Changed Files ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
		end)
	end)
end

---Show PR build statuses in a scrollable buffer
---@param pr table
function M.show_pr_statuses_view(pr)
	if not pr or not pr.workspace or not pr.repo or not pr.id then
		vim.notify("Invalid PR data", vim.log.levels.ERROR)
		return
	end

	local common_ui = require("atlas.common.ui")
	common_ui.start_loading("Loading build statuses...")

	local bb_api = require("atlas.bitbucket-api.api")
	bb_api.get_pr_statuses(pr.workspace, pr.repo, pr.id, function(result, err)
		vim.schedule(function()
			common_ui.stop_loading()
			if err then
				vim.notify("Error fetching statuses: " .. err, vim.log.levels.ERROR)
				return
			end

			local statuses = (result and result.values) or {}
			if #statuses == 0 then
				vim.notify("No build statuses for this PR", vim.log.levels.INFO)
				return
			end

			local lines = { " Build Statuses for PR #" .. pr.id, " " .. ("━"):rep(50), "" }
			for _, status in ipairs(statuses) do
				local name = status.name or status.key or "Unknown"
				local state_val = status.state or "UNKNOWN"
				local desc = status.description or ""
				local url = (status.url or ""):sub(1, 60)
				
				local icon, hl = get_build_display(state_val)
				table.insert(lines, string.format("%-15s  %s", state_val, name))
				if desc ~= "" then
					table.insert(lines, "  " .. desc)
				end
				if url ~= "" then
					table.insert(lines, "  URL: " .. url)
				end
				table.insert(lines, "")
			end

			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			api.nvim_set_option_value("modifiable", false, { buf = buf })
			api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

			local width = math.min(100, vim.o.columns - 10)
			local height = math.min(40, vim.o.lines - 5)
			local win = api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				col = (vim.o.columns - width) / 2,
				row = (vim.o.lines - height) / 2,
				style = "minimal",
				border = "rounded",
				title = " Build Statuses ",
				title_pos = "center",
			})

			vim.keymap.set("n", "q", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<Esc>", function()
				api.nvim_win_close(win, true)
			end, { buffer = buf, nowait = true })
		end)
	end)
end

return M
