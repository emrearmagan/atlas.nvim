local M = {}

local notify = require("atlas.core.notify")
local actions = require("atlas.pulls.ui.pipelines.actions")
local keymaps = require("atlas.pulls.ui.pipelines.keymaps")
local logs = require("atlas.pulls.ui.pipelines.logs")
local renderer = require("atlas.pulls.ui.pipelines.renderer")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local valid_buf = utils.buffer.valid
local valid_win = utils.window.valid
local namespace = vim.api.nvim_create_namespace("atlas.pipelines")
local ACTION_REFRESH_DELAY_MS = 1000
local active_session

---@class PullsPipelineSelection
---@field pipeline PullsPipeline
---@field stage string|nil
---@field job PullsPipelineJob|nil
---@field step PullsPipelineStep|nil

---@param buf integer
---@param lines string[]
---@param spans table[]|nil
local function set_buffer_content(buf, lines, spans)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, span in ipairs(spans or {}) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param name string
---@param lines string[]
---@param spans table[]
---@return integer
local function create_buffer(name, lines, spans)
	local buf = utils.buffer.create(name, "")
	set_buffer_content(buf, lines, spans)
	return buf
end

---@param win integer
---@param buf integer
---@param title string
local function configure_window(win, buf, title)
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
	vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winbar", " " .. title .. " ", { win = win })
end

---@param win integer
---@param buf integer
local function restore_detail_window(win, buf)
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("breakindent", true, { win = win })
	vim.api.nvim_set_option_value("winbar", " ", { win = win })
end

---@param line_map table<integer, PullsPipelineSelection>
---@param selected_pipeline PullsPipeline|nil
---@param selected_job PullsPipelineJob|nil
---@return integer
local function selected_pipeline_line(line_map, selected_pipeline, selected_job)
	local pipeline_line = 1
	for lnum = 1, #line_map do
		local selection = line_map[lnum]
		if selection and selection.pipeline == selected_pipeline then
			if selected_job and selection.job == selected_job then
				return lnum
			end
			if selection.job == nil then
				pipeline_line = lnum
				if selected_job == nil then
					return lnum
				end
			end
		end
	end
	return pipeline_line
end

---@param session table
---@return PullsPipelineSelection|nil
local function current_selection(session)
	if not valid_win(session.pipeline_win) then
		return nil
	end
	return session.line_map[vim.api.nvim_win_get_cursor(session.pipeline_win)[1]]
end

---@param url string|nil
local function open_url(url)
	if type(url) ~= "string" or url == "" then
		notify.warn("No pipeline URL available")
		return
	end
	local ok, result, err = pcall(vim.ui.open, url)
	if not ok or (result == nil and err ~= nil) then
		notify.error(string.format("Failed to open URL: %s", tostring(ok and err or result)))
		return
	end
end

---@param selection PullsPipelineSelection|nil
local function open_selection_url(selection)
	if not selection then
		open_url(nil)
		return
	end
	local url = selection.job and selection.job.url or nil
	open_url(type(url) == "string" and url ~= "" and url or selection.pipeline.url)
end

---@param session table
---@param pipelines PullsPipeline[]
local function render_pipelines(session, pipelines)
	local width = valid_win(session.pipeline_win) and vim.api.nvim_win_get_width(session.pipeline_win) or vim.o.columns
	local lines, line_map, spans = renderer.render(pipelines, width)
	session.pipelines = pipelines
	session.line_map = line_map
	set_buffer_content(session.pipeline_buf, lines, spans)
	if session.initial_selection_pending and valid_win(session.pipeline_win) then
		local pipeline = session.initial_pipeline or pipelines[1]
		if pipeline then
			vim.api.nvim_win_set_cursor(
				session.pipeline_win,
				{ selected_pipeline_line(line_map, pipeline, session.initial_job), 0 }
			)
		end
		session.initial_selection_pending = false
		session.initial_pipeline = nil
		session.initial_job = nil
	end
end

---@param session table
---@param pipelines PullsPipeline[]
---@param force_refresh boolean
---@param on_done fun(pipelines: PullsPipeline[], err: string|nil)
local function fetch_pipeline_details(session, pipelines, force_refresh, on_done)
	if #pipelines == 0 then
		on_done(pipelines, nil)
		return
	end

	local pending = #pipelines
	local details = {}
	local first_err
	for index, pipeline in ipairs(pipelines) do
		session.provider.fetch_pipeline_details(
			session.pr,
			pipeline,
			{ force_refresh = force_refresh },
			function(result, err)
				if session.closed then
					return
				end
				details[index] = result or pipeline
				first_err = first_err or err
				pending = pending - 1
				if pending == 0 then
					on_done(details, first_err)
				end
			end
		)
	end
end

---@param session table
local function stop_pipeline_spinner(session)
	if session.spinner then
		session.spinner:stop()
		session.spinner = nil
	end
end

---@param session table
---@param frame string|nil
local function render_pipeline_loading(session, frame)
	if not valid_buf(session.pipeline_buf) or not valid_win(session.pipeline_win) then
		return
	end
	local text = frame and string.format("%s Loading...", frame) or spinner.with_text("Loading...")
	local width = vim.api.nvim_win_get_width(session.pipeline_win)
	local height = vim.api.nvim_win_get_height(session.pipeline_win)
	local row = math.max(0, math.floor((height - 1) / 2))
	local padding = math.max(0, math.floor((width - vim.api.nvim_strwidth(text)) / 2))
	local lines = {}
	for _ = 1, row do
		table.insert(lines, "")
	end
	table.insert(lines, string.rep(" ", padding) .. text)
	session.line_map = {}
	set_buffer_content(session.pipeline_buf, lines, {})
end

---@param session table
local function start_pipeline_spinner(session)
	stop_pipeline_spinner(session)
	render_pipeline_loading(session)
	session.spinner = spinner.create({
		on_tick = function(frame)
			if not session.refreshing or not valid_buf(session.pipeline_buf) then
				stop_pipeline_spinner(session)
				return
			end
			render_pipeline_loading(session, frame)
		end,
	})
	session.spinner:start()
end

---@param session table
---@param delay_ms integer|nil
---@param force_refresh boolean|nil
local function reload_pipelines(session, delay_ms, force_refresh)
	if session.refreshing then
		return
	end
	local provider = session.provider
	if not (provider and type(provider.fetch_pipelines) == "function") then
		notify.warn("Pipeline refresh is not supported by this provider")
		return
	end

	session.refreshing = true
	start_pipeline_spinner(session)
	local function fetch()
		if session.closed then
			return
		end
		provider.fetch_pipelines(session.pr, { force_refresh = force_refresh ~= false }, function(pipelines, err)
			if session.closed then
				return
			end
			if err then
				session.refreshing = false
				stop_pipeline_spinner(session)
				render_pipelines(session, session.pipelines)
				notify.error(string.format("Failed to refresh pipelines: %s", tostring(err)))
				return
			end

			fetch_pipeline_details(
				session,
				type(pipelines) == "table" and pipelines or {},
				force_refresh ~= false,
				function(details, details_err)
					session.refreshing = false
					stop_pipeline_spinner(session)
					render_pipelines(session, details)
					if details_err then
						notify.error(string.format("Failed to load pipeline details: %s", tostring(details_err)))
					end
				end
			)
		end)
	end

	if delay_ms and delay_ms > 0 then
		vim.defer_fn(fetch, delay_ms)
	else
		fetch()
	end
end

---@param session table
---@param selection PullsPipelineSelection|nil
local function open_pipeline_actions(session, selection)
	if not selection then
		notify.warn("No pipeline selected")
		return
	end

	local ctx = { pr = session.pr, pipeline = selection.pipeline, job = selection.job }
	actions.open(session.provider, ctx, function(action)
		action.run(ctx, function(err)
			if session.closed then
				return
			end
			if err then
				notify.error(string.format("%s failed: %s", action.label, tostring(err)))
				return
			end
			reload_pipelines(session, ACTION_REFRESH_DELAY_MS)
		end)
	end)
end

---@param session table
local function cleanup_session(session)
	session.closed = true
	session.refreshing = false
	stop_pipeline_spinner(session)
	if active_session == session then
		active_session = nil
	end
end

---@param session table
local function close_session(session)
	local layout = require("atlas.ui.layout")
	if session.owns_detail_window then
		layout.toggle_detail()
	else
		restore_detail_window(session.pipeline_win, session.previous_buf)
	end
end

---@param pr PullRequest
---@param pipelines PullsPipeline[]|nil
---@param selected_pipeline PullsPipeline|nil
---@param selected_job PullsPipelineJob|nil
function M.open(pr, pipelines, selected_pipeline, selected_job)
	local fetch_on_open = type(pipelines) ~= "table"
	pipelines = type(pipelines) == "table" and pipelines or {}

	if active_session then
		close_session(active_session)
	end

	local layout = require("atlas.ui.layout")
	layout.ensure_open()
	local owns_detail_window = layout.win_id("detail") == nil
	if owns_detail_window then
		layout.toggle_detail()
	end
	local pipeline_win = layout.win_id("detail")
	if not valid_win(pipeline_win) then
		notify.error("Failed to open the pipeline pane")
		return
	end

	local provider = require("atlas.pulls.state").provider
	local lines, line_map, spans = renderer.render(pipelines, vim.api.nvim_win_get_width(pipeline_win))
	local session = {
		pipelines = pipelines,
		closed = false,
		line_map = line_map,
		pr = pr,
		provider = provider,
		refreshing = false,
		initial_selection_pending = true,
		initial_pipeline = selected_pipeline,
		initial_job = selected_job,
		pipeline_win = pipeline_win,
		previous_buf = vim.api.nvim_win_get_buf(pipeline_win),
		owns_detail_window = owns_detail_window,
	}
	session.pipeline_buf = create_buffer("atlas://pipelines", lines, spans)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = session.pipeline_buf })
	active_session = session

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = session.pipeline_buf,
		once = true,
		callback = function()
			cleanup_session(session)
		end,
	})

	configure_window(session.pipeline_win, session.pipeline_buf, "Pipelines")
	vim.api.nvim_win_set_cursor(
		session.pipeline_win,
		{ selected_pipeline_line(line_map, selected_pipeline, selected_job), 0 }
	)

	keymaps.setup_pipelines(session.pipeline_buf, "Pipelines", {
		close = function()
			close_session(session)
		end,
		show_logs = function()
			local selection = current_selection(session)
			if selection and selection.job then
				logs.open(session.pr, session.provider, selection)
			end
		end,
		refresh = function()
			reload_pipelines(session)
		end,
		open_url = function()
			open_selection_url(current_selection(session))
		end,
		open_actions = function()
			open_pipeline_actions(session, current_selection(session))
		end,
	})

	vim.api.nvim_set_current_win(session.pipeline_win)
	if fetch_on_open then
		reload_pipelines(session, nil, false)
	else
		session.refreshing = true
		start_pipeline_spinner(session)
		fetch_pipeline_details(session, pipelines, false, function(details, err)
			session.refreshing = false
			stop_pipeline_spinner(session)
			render_pipelines(session, details)
			if err then
				notify.error(string.format("Failed to load pipeline details: %s", tostring(err)))
			end
		end)
	end
end

return M
