local M = {}

local keymaps = require("atlas.pulls.ui.pipelines.keymaps")
local statusline = require("atlas.ui.statusline")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas.pipeline-job-log")

local TERMINAL_ESCAPE_PATTERN = [[\%x1b\%(\[[0-?]*[ -/]*[@-~]\|\].\{-}\%(\%x07\|\%x1b\\\)\|[ -/]*[0-~]\)]]

local LOG_HIGHLIGHT_RULES = {
	{
		hl_group = "AtlasLogError",
		patterns = {
			"^##%[error%]",
			"^%[error%]",
			"^error:",
			"^failed:",
			"^failed[%.!]*$",
			"^failure[%.!]*$",
			"^%w[%w%s_%-]* failed[%.!]*$",
			"^job failed[:%.!].*$",
			"^process completed with exit code [1-9]%d*[%.!]*$",
		},
	},
	{
		hl_group = "AtlasLogWarn",
		patterns = {
			"^##%[warning%]",
			"^%[warning%]",
			"^%[warn%]",
			"^warning:",
			"^warn:",
			"deprecated",
		},
	},
	{
		hl_group = "AtlasLogInfo",
		patterns = {
			"^##%[notice%]",
			"^%[notice%]",
			"^%[info%]",
			"^notice:",
			"^info:",
		},
	},
	{
		hl_group = "AtlasTextPositive",
		patterns = {
			"^%[success%]",
			"^%[passed%]",
			"^success:",
			"^passed:",
			"^passed[%.!]*$",
			"^%w[%w%s_%-]* passed[%.!]*$",
			"^%w[%w%s_%-]* succeeded[%.!]*$",
			"^process completed with exit code 0[%.!]*$",
		},
	},
}

---@param line string
---@return integer|nil
local function log_timestamp_end(line)
	local _, timestamp_end = line:find("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d")
	if not timestamp_end then
		return nil
	end

	local fraction = line:sub(timestamp_end + 1):match("^[.,]%d+")
	if fraction then
		timestamp_end = timestamp_end + #fraction
	end

	local suffix = line:sub(timestamp_end + 1)
	if suffix:match("^[Zz]") then
		timestamp_end = timestamp_end + 1
	else
		local timezone = suffix:match("^[+%-]%d%d:%d%d")
		if timezone then
			timestamp_end = timestamp_end + #timezone
		end
	end

	return timestamp_end
end

---@param content string
---@return string|nil
local function log_message_hl(content)
	local normalized = vim.trim(content):lower()
	for _, rule in ipairs(LOG_HIGHLIGHT_RULES) do
		for _, pattern in ipairs(rule.patterns) do
			if normalized:match(pattern) then
				return rule.hl_group
			end
		end
	end
	return nil
end

---@param spans table[]
---@param line integer
---@param start_col integer
---@param end_col integer
---@param hl_group string
local function push_span(spans, line, start_col, end_col, hl_group)
	if end_col > start_col then
		table.insert(spans, {
			line = line,
			start_col = start_col,
			end_col = end_col,
			hl_group = hl_group,
		})
	end
end

---@param text string
---@return string
local function strip_terminal_sequences(text)
	return vim.fn.substitute(text, TERMINAL_ESCAPE_PATTERN, "", "g")
end

---@param spans table[]
---@param line_index integer
---@param line string
---@param start_col integer
local function highlight_message(spans, line_index, line, start_col)
	local content = line:sub(start_col + 1)
	local trace_prefix = content:match("^(%d%d%u%+)")
	local trace_section = trace_prefix ~= nil
	trace_prefix = trace_prefix or content:match("^(%d%d%u%s+)")
	if trace_prefix then
		local marker_end = start_col + #trace_prefix
		push_span(spans, line_index, start_col, marker_end, "AtlasTextMuted")
		start_col = marker_end
		content = line:sub(start_col + 1)
	end

	if trace_section then
		push_span(spans, line_index, start_col, #line, "AtlasColumnHeader")
		return
	end

	local group_marker = content:match("^(##%[group%])")
	if group_marker then
		local marker_end = start_col + #group_marker
		push_span(spans, line_index, start_col, marker_end, "AtlasTextMuted")
		push_span(spans, line_index, marker_end, #line, "AtlasColumnHeader")
		return
	end
	if content:match("^##%[endgroup%]") then
		push_span(spans, line_index, start_col, #line, "AtlasTextMuted")
		return
	end

	local command_marker = content:match("^(##%[command%])")
		or content:match("^(%[command%])")
		or content:match("^(%$%s+)")
		or content:match("^(%+%s+)")
	if command_marker then
		local marker_end = start_col + #command_marker
		push_span(spans, line_index, start_col, marker_end, "AtlasTextMuted")
		push_span(spans, line_index, marker_end, #line, "AtlasLogInfo")
		return
	end

	local message_hl = log_message_hl(content)
	if message_hl then
		push_span(spans, line_index, start_col, #line, message_hl)
	end
end

---@param log string
---@return string[], table[]
local function render_log(log)
	local text = tostring(log or ""):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	text = strip_terminal_sequences(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end

	local spans = {}
	for line_index, line in ipairs(lines) do
		local timestamp_end = log_timestamp_end(line)
		if timestamp_end then
			push_span(spans, line_index - 1, 0, timestamp_end, "AtlasTextMuted")
		end

		local message_start = line:find("%S", (timestamp_end or 0) + 1)
		if message_start then
			highlight_message(spans, line_index - 1, line, message_start - 1)
		end
	end
	return lines, spans
end

---@class PullsPipelineLogSession
---@field pr PullRequest
---@field provider PullsProvider|nil
---@field pipeline PullsPipeline
---@field job PullsPipelineJob
---@field win integer
---@field buf integer
---@field request { cancel: fun() }|nil
---@field spinner table|nil
---@field frame string|nil
---@field status "loading"|"loaded"|"error"
---@field log string
---@field error string

---@param seconds number|nil
---@return string
local function duration_text(seconds)
	local value = tonumber(seconds)
	if value == nil then
		return ""
	end
	if value < 60 then
		return string.format("%ds", math.floor(value))
	end
	return utils.human_duration(value)
end

---@param pipeline PullsPipeline
---@return string
local function pipeline_name(pipeline)
	local name = tostring(pipeline.name or pipeline.key or "")
	return name ~= "" and name or "Pipeline"
end

---@param state string
---@return string
local function status_text(state)
	local labels = {
		FAILED = "Failed",
		INPROGRESS = "In progress",
		STOPPED = "Stopped",
		SUCCESSFUL = "Successful",
		UNKNOWN = "Unknown",
	}
	return labels[state:upper()] or state
end

---@param session PullsPipelineLogSession
---@param lines string[]
---@param spans table[]
local function set_content(session, lines, spans)
	if not vim.api.nvim_buf_is_valid(session.buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = session.buf })
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(session.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(session.buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	vim.api.nvim_set_option_value("modifiable", false, { buf = session.buf })
end

---@param session PullsPipelineLogSession
local function render(session)
	if not vim.api.nvim_win_is_valid(session.win) then
		return
	end

	local width = vim.api.nvim_win_get_width(session.win)
	local state = tostring(session.job.state or "UNKNOWN"):upper()
	local status_icon, status_hl = icons.pulls_status(state:lower())
	local status = status_text(state)
	local name = tostring(session.job.name or "Job")
	local icon_start = 2
	local name_start = icon_start + #status_icon + 1
	local status_start = name_start + #name + 2
	local title = string.format("  %s %s  %s", status_icon, name, status)

	local metadata = { pipeline_name(session.pipeline) }
	local duration = duration_text(session.job.duration)
	if duration ~= "" then
		table.insert(metadata, duration)
	end
	local started = utils.relative_time_text(session.job.started_at)
	if started ~= "-" then
		table.insert(metadata, "Started " .. started)
	end
	local metadata_line = "  " .. table.concat(metadata, "  ")
	local divider = string.rep("─", math.max(width - 2, 1))
	local lines = { "", title, metadata_line, "", divider, "" }
	local spans = {
		{ line = 1, start_col = name_start, end_col = name_start + #name, hl_group = "AtlasColumnHeader" },
		{
			line = 1,
			start_col = icon_start,
			end_col = icon_start + #status_icon,
			hl_group = status_hl,
		},
		{
			line = 1,
			start_col = status_start,
			end_col = status_start + #status,
			hl_group = status_hl,
		},
		{ line = 4, start_col = 0, end_col = #divider, hl_group = "AtlasTextMuted" },
	}

	if session.status == "loading" then
		local text = session.frame and string.format("%s Loading...", session.frame) or spinner.with_text("Loading...")
		table.insert(lines, "  " .. text)
	elseif session.status == "error" then
		table.insert(lines, session.error)
		table.insert(spans, {
			line = #lines - 1,
			start_col = 0,
			end_col = #session.error,
			hl_group = "AtlasLogError",
		})
	else
		local log_lines, log_spans = render_log(session.log)
		local offset = #lines
		for _, line in ipairs(log_lines) do
			table.insert(lines, line)
		end
		for _, span in ipairs(log_spans) do
			table.insert(spans, {
				line = span.line + offset,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end

	set_content(session, lines, spans)
end

---@param session PullsPipelineLogSession
local function stop_spinner(session)
	if session.spinner then
		session.spinner:stop()
		session.spinner = nil
	end
	session.frame = nil
end

---@param session PullsPipelineLogSession
local function cancel_request(session)
	if session.request and type(session.request.cancel) == "function" then
		session.request.cancel()
	end
	session.request = nil
end

---@param session PullsPipelineLogSession
local function start_spinner(session)
	stop_spinner(session)
	session.spinner = spinner.create({
		on_tick = function(frame)
			if session.status ~= "loading" then
				stop_spinner(session)
				return
			end
			session.frame = frame
			render(session)
		end,
	})
	session.spinner:start()
end

---@param session PullsPipelineLogSession
local function fetch_log(session)
	cancel_request(session)
	session.status = "loading"
	session.log = ""
	session.error = ""
	render(session)
	start_spinner(session)

	local pipelines = session.provider and session.provider.capabilities.pipelines
	if not pipelines or not pipelines.fetch_job_log then
		stop_spinner(session)
		session.status = "error"
		session.error = "Job logs are not supported by this provider"
		render(session)
		return
	end

	session.request = pipelines.fetch_job_log(session.pr, session.pipeline, session.job, function(log, err)
		session.request = nil
		stop_spinner(session)
		if err then
			session.status = "error"
			session.error = "Failed to load job logs: " .. tostring(err)
		else
			session.status = "loaded"
			session.log = tostring(log or "")
		end
		render(session)
	end)
end

---@param session PullsPipelineLogSession
local function cleanup(session)
	cancel_request(session)
	stop_spinner(session)
end

---@param win integer
local function configure_window(win)
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
	vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("winbar", " Job Log ", { win = win })
	statusline.attach(win)
end

---@param pr PullRequest
---@param provider PullsProvider|nil
---@param selection PullsPipelineSelection
function M.open(pr, provider, selection)
	if not selection.job then
		return
	end

	vim.cmd("tabnew")
	local tab = vim.api.nvim_get_current_tabpage()
	local placeholder_buf = vim.api.nvim_get_current_buf()
	local session = {
		pr = pr,
		provider = provider,
		pipeline = selection.pipeline,
		job = selection.job,
		win = vim.api.nvim_get_current_win(),
		buf = utils.buffer.create(string.format("atlas://pipeline-job-log/%d", tab), ""),
		status = "loading",
		log = "",
		error = "",
	}
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = session.buf })
	vim.api.nvim_win_set_buf(session.win, session.buf)
	configure_window(session.win)
	if placeholder_buf ~= session.buf then
		utils.buffer.delete(placeholder_buf)
	end

	keymaps.setup_job_log(session.buf, {
		refresh = function()
			fetch_log(session)
		end,
		open_url = function()
			local url = session.job.url or session.pipeline.url
			if type(url) == "string" and url ~= "" then
				vim.ui.open(url)
			end
		end,
		close = function()
			vim.cmd("tabclose")
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = session.buf,
		once = true,
		callback = function()
			cleanup(session)
		end,
	})

	fetch_log(session)
end

return M
