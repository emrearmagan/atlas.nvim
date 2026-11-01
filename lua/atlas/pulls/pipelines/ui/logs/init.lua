local logger = require("atlas.core.logger")
local requests = require("atlas.core.requests")
local parser = require("atlas.pulls.pipelines.parser")
local renderer = require("atlas.pulls.pipelines.ui.logs.renderer")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

---@class PullsPipelinesLogs
---@field buf integer|nil
---@field win integer|nil
---@field context PullsPipelineContext
---@field backend PullsPipelineBackend|nil
---@field requests AtlasRequestScope|nil
---@field selection PullsPipelinesSelection|nil
---@field log (PullsLogLine|PullsLogGroup)[]|"loading"|string|nil
---@field source PullsLog|nil
---@field counts table<PullsLogLevel, integer>|nil
---@field show_raw boolean|nil
---@field collapsed table<string, boolean>
---@field default_collapsed boolean|nil
---@field line_map table<integer, PullsLogGroup>
---@field entry_rows table<PullsLogLine|PullsLogGroup, integer>
---@field spinner SpinnerInstance|nil
---@field refresh_timer uv.uv_timer_t|nil
---@field refreshing boolean|nil
---@field follow_pending boolean|nil
---@field refresh_complete boolean|nil
---@field on_update fun()|nil
---@field on_reload fun(selection: PullsPipelinesSelection, opts?: { background?: boolean })|nil

local M = {}

local running_states = { INPROGRESS = true, QUEUED = true, PENDING = true }

---@param job PullsPipelineJob
---@return boolean
local function is_finished(job)
	return not running_states[job.state]
end

M.render = renderer.render

---@param pane PullsPipelinesLogs
---@param entries (PullsLogLine|PullsLogGroup)[]
---@param prefix string
local function set_fold_keys(pane, entries, prefix)
	for index, entry in ipairs(entries) do
		if entry.entries then
			entry.fold_key = prefix .. index
			if pane.default_collapsed == false and pane.collapsed[entry.fold_key] == nil then
				pane.collapsed[entry.fold_key] = false
			end
			set_fold_keys(pane, entry.entries, entry.fold_key .. ".")
		end
	end
end

---@param entries (PullsLogLine|PullsLogGroup)[]
---@param target PullsLogLine|PullsLogGroup
---@param collapsed table<string, boolean>
---@return boolean
local function reveal(entries, target, collapsed)
	for _, entry in ipairs(entries) do
		if entry == target then
			if entry.entries then
				collapsed[entry.fold_key] = false
			end
			return true
		end
		if entry.entries and reveal(entry.entries, target, collapsed) then
			collapsed[entry.fold_key] = false
			return true
		end
	end
	return false
end

---@param pane PullsPipelinesLogs
---@return boolean
local function is_following(pane)
	if not pane.refresh_timer or not utils.window.has_buffer(pane.win, pane.buf) then
		return false
	end
	if pane.follow_pending then
		return true
	end
	return type(pane.log) == "table"
		and vim.api.nvim_win_get_cursor(pane.win)[1] == vim.api.nvim_buf_line_count(pane.buf)
end

---@param pane PullsPipelinesLogs
---@param following boolean|nil
local function render(pane, following)
	M.render(pane)
	if following and renderer.has_content(pane) and utils.window.has_buffer(pane.win, pane.buf) then
		vim.api.nvim_win_set_cursor(pane.win, { vim.api.nvim_buf_line_count(pane.buf), 0 })
		pane.follow_pending = false
	end
end

---@param pane PullsPipelinesLogs
---@param target PullsLogLine|PullsLogGroup
---@return boolean
function M.jump(pane, target)
	local log = pane.log
	if type(log) ~= "table" or not utils.window.valid(pane.win) then
		return false
	end
	if not pane.show_raw then
		if not reveal(log, target, pane.collapsed) then
			return false
		end
	end
	M.render(pane)
	local row = pane.entry_rows[target]
	if row then
		vim.api.nvim_win_set_cursor(pane.win, { row, 0 })
		vim.api.nvim_win_call(pane.win, function()
			vim.cmd("normal! zz")
		end)
	end
	return true
end

---@param pane PullsPipelinesLogs
---@return PullsLogLine|PullsLogGroup|nil
local function step_target(pane)
	local selection = pane.selection
	local log = pane.log
	local resolve = pane.backend and pane.backend.step_target
	if not selection or not selection.job or not selection.step or type(log) ~= "table" or not resolve then
		return
	end
	local step = selection.job.steps and selection.job.steps[selection.step]
	local entries = pane.show_raw and pane.source and pane.source.lines or log
	return step and resolve(entries, step)
end

---@param pane PullsPipelinesLogs
---@param target PullsLogLine|PullsLogGroup|nil
---@param following boolean|nil
local function update(pane, target, following)
	following = following and renderer.has_content(pane)
	if following or not (target and M.jump(pane, target)) then
		render(pane, following)
	end
	if pane.on_update then
		pane.on_update()
	end
end

---@param pane PullsPipelinesLogs
local function stop_spinner(pane)
	if pane.spinner then
		pane.spinner:stop()
		pane.spinner = nil
		renderer.render_spinner(pane)
	end
end

---@param pane PullsPipelinesLogs
---@return boolean
local function sync_spinner(pane)
	local previous = pane.spinner
	local job = pane.selection and pane.selection.job
	local waiting = pane.refresh_timer and job and not (is_finished(job) and pane.refresh_complete)
	if pane.log == "loading" or (waiting and type(pane.log) == "table") then
		if not pane.spinner then
			---@type SpinnerInstance
			local loading_spinner
			loading_spinner = spinner.create({
				on_tick = function()
					if pane.spinner == loading_spinner then
						if pane.log == "loading" then
							M.render(pane)
						else
							renderer.render_spinner(pane)
						end
					end
				end,
			})
			pane.spinner = loading_spinner
			loading_spinner:start()
		end
	else
		stop_spinner(pane)
	end
	return pane.spinner ~= previous
end

---@param pane PullsPipelinesLogs
---@param on_update fun()
---@param on_reload fun(selection: PullsPipelinesSelection, opts?: { background?: boolean })
function M.setup(pane, on_update, on_reload)
	pane.on_update = on_update
	pane.on_reload = on_reload
	vim.api.nvim_set_option_value("cursorline", false, { win = pane.win })
	vim.api.nvim_set_option_value("winfixwidth", false, { win = pane.win })
	update(pane)
end

---@param pane PullsPipelinesLogs
---@param selection PullsPipelinesSelection|nil
---@param opts { force_refresh?: boolean, background?: boolean }|nil
function M.show(pane, selection, opts)
	opts = opts or {}
	local same_job = selection and selection.job and pane.selection and selection.job == pane.selection.job
	local background = opts.background and same_job
	if not same_job then
		pane.collapsed = {}
		pane.default_collapsed = nil
		pane.follow_pending = pane.refresh_timer ~= nil and not (selection and selection.step)
		pane.refresh_complete = false
	end
	if same_job and opts.force_refresh ~= true and pane.log ~= nil then
		---@cast selection PullsPipelinesSelection
		if selection.step and selection.step ~= pane.selection.step then
			pane.follow_pending = false
		end
		pane.selection = selection
		update(pane, step_target(pane))
		return
	end
	if same_job and not background then
		pane.follow_pending = is_following(pane)
	end

	if pane.requests then
		pane.requests.cancel()
	end
	pane.refreshing = false
	pane.selection = selection
	if not background then
		stop_spinner(pane)
		pane.log = nil
		pane.source = nil
		pane.counts = nil
		pane.line_map = {}
	end
	if not same_job then
		vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
	end

	if not selection or not selection.pipeline or not selection.job then
		update(pane)
		return
	end

	local fetch = pane.backend and pane.backend.fetch_job_log
	if not fetch then
		pane.log = "Job logs are not supported by this provider"
		update(pane)
		return
	end

	-- The job can finish while we're fetching logs, so check its state now.
	local finished = is_finished(selection.job)

	pane.requests = requests.new()
	pane.refreshing = true
	if not background then
		pane.log = "loading"
		sync_spinner(pane)
		M.render(pane)
	end
	if pane.on_update then
		pane.on_update()
	end

	pane.requests.run(function(done)
		return fetch(pane.context, selection.pipeline, selection.job, done)
	end, function(log, err)
		pane.refreshing = false
		pane.refresh_complete = finished and not err
		local following = is_following(pane)
		local changed = false
		if err then
			logger.logerror("Fetch job logs failed", { job_id = selection.job.id, error = err })
			if not background then
				pane.log = err
			end
		elseif not pane.source or pane.source.raw ~= (log and log.raw or "") then
			pane.source = log or { raw = "" }
			local entries = parser.parse(pane.source, pane.backend.parse)
			set_fold_keys(pane, entries, "")
			pane.log = entries
			changed = true
		end
		local spinner_changed = sync_spinner(pane)
		if not background then
			update(pane, step_target(pane), following)
			return
		end
		if changed or spinner_changed then
			render(pane, following)
		end
		if pane.on_update then
			pane.on_update()
		end
	end)
end

---@param pane PullsPipelinesLogs
function M.toggle_auto_refresh(pane)
	if pane.refresh_timer then
		pane.refresh_timer:close()
		pane.refresh_timer = nil
		pane.follow_pending = false
	else
		local timer = vim.uv.new_timer()
		pane.refresh_timer = timer
		pane.follow_pending = true
		timer:start(
			5000,
			5000,
			vim.schedule_wrap(function()
				local job = pane.selection and pane.selection.job
				if pane.refresh_timer ~= timer or not job or pane.refreshing then
					return
				end

				-- Fetch once after the job finishes so we don't miss the last lines.
				if is_finished(job) and pane.refresh_complete then
					return
				end

				pane.on_reload(pane.selection, { background = true })
			end)
		)
	end
	sync_spinner(pane)
	render(pane, pane.refresh_timer ~= nil)
end

---@param pane PullsPipelinesLogs
function M.toggle_raw(pane)
	local following = is_following(pane)
	pane.show_raw = not pane.show_raw
	render(pane, following)
end

---@param pane PullsPipelinesLogs
function M.toggle_fold(pane)
	if not utils.window.valid(pane.win) then
		return
	end
	local row = vim.api.nvim_win_get_cursor(pane.win)[1]
	local group = pane.line_map[row]
	if group then
		pane.collapsed[group.fold_key] = pane.collapsed[group.fold_key] == false
		M.render(pane)
	end
end

---@param pane PullsPipelinesLogs
function M.toggle_all_folds(pane)
	local log = pane.log
	if pane.show_raw or type(log) ~= "table" then
		return
	end
	local collapse = false
	for _, entry in ipairs(log) do
		if entry.entries and pane.collapsed[entry.fold_key] == false then
			collapse = true
			break
		end
	end

	local function set_collapsed(entries)
		for _, entry in ipairs(entries) do
			if entry.entries then
				pane.collapsed[entry.fold_key] = collapse
				set_collapsed(entry.entries)
			end
		end
	end
	pane.default_collapsed = collapse
	set_collapsed(log)
	M.render(pane)
end

---@param pane PullsPipelinesLogs
function M.dispose(pane)
	if pane.refresh_timer then
		pane.refresh_timer:close()
		pane.refresh_timer = nil
	end
	if pane.requests then
		pane.requests.cancel()
	end
	pane.refreshing = false
	stop_spinner(pane)
	pane.on_update = nil
	pane.on_reload = nil
end

return M
