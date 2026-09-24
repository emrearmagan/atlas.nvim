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
---@field line_map table<integer, PullsLogGroup>
---@field entry_rows table<PullsLogLine|PullsLogGroup, integer>
---@field spinner SpinnerInstance|nil
---@field refresh_timer uv.uv_timer_t|nil
---@field refreshing boolean|nil
---@field on_update fun()|nil
---@field on_reload fun(selection: PullsPipelinesSelection, opts?: { background?: boolean })|nil

local M = {}

---@param pane PullsPipelinesLogs
function M.render(pane)
	renderer.render(pane)
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
---@param target PullsLogLine|PullsLogGroup
function M.jump(pane, target)
	local log = pane.log
	if type(log) ~= "table" or not utils.window.valid(pane.win) then
		return
	end
	if not pane.show_raw then
		if not reveal(log, target, pane.collapsed) then
			return
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
end

---@param pane PullsPipelinesLogs
local function jump_to_step(pane)
	local selection = pane.selection
	local log = pane.log
	local resolve = pane.backend and pane.backend.step_target
	if not selection or not selection.job or not selection.step or type(log) ~= "table" or not resolve then
		return
	end
	local step = selection.job.steps and selection.job.steps[selection.step]
	local entries = pane.show_raw and pane.source.lines or log
	local target = step and resolve(entries, step)
	if target then
		M.jump(pane, target)
	end
end

---@param pane PullsPipelinesLogs
local function update(pane)
	M.render(pane)
	if pane.on_update then
		pane.on_update()
	end
end

---@param pane PullsPipelinesLogs
local function stop_spinner(pane)
	if pane.spinner then
		pane.spinner:stop()
		pane.spinner = nil
	end
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
---@param opts { force_refresh?: boolean, background?: boolean, reset_folds?: boolean }|nil
function M.show(pane, selection, opts)
	opts = opts or {}
	local same_job = selection and selection.job and pane.selection and selection.job == pane.selection.job
	local background = opts.background and same_job
	if not same_job or opts.reset_folds then
		pane.collapsed = {}
	end
	if same_job and opts.force_refresh ~= true and pane.log ~= nil then
		pane.selection = selection
		update(pane)
		jump_to_step(pane)
		return
	end

	if pane.requests then
		pane.requests.cancel()
	end
	pane.refreshing = false
	stop_spinner(pane)
	pane.selection = selection
	if not background then
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

	pane.requests = requests.new()
	pane.refreshing = true
	if not background then
		pane.log = "loading"
		---@type SpinnerInstance
		local loading_spinner
		loading_spinner = spinner.create({
			on_tick = function()
				if pane.spinner == loading_spinner then
					M.render(pane)
				end
			end,
		})
		pane.spinner = loading_spinner
		M.render(pane)
		loading_spinner:start()
	end
	if pane.on_update then
		pane.on_update()
	end

	pane.requests.run(function(done)
		return fetch(pane.context, selection.pipeline, selection.job, done)
	end, function(log, err)
		pane.refreshing = false
		stop_spinner(pane)
		if err then
			logger.logerror("Fetch job logs failed", { job_id = selection.job.id, error = err })
			if not background then
				pane.log = err
				M.render(pane)
			end
		elseif not pane.source or pane.source.raw ~= (log and log.raw or "") then
			pane.source = log or { raw = "" }
			pane.log = parser.parse(pane.source, pane.backend.parse)
			M.render(pane)
		end
		if pane.on_update then
			pane.on_update()
		end
		if not background then
			jump_to_step(pane)
		end
	end)
end

---@param pane PullsPipelinesLogs
function M.toggle_auto_refresh(pane)
	if pane.refresh_timer then
		pane.refresh_timer:close()
		pane.refresh_timer = nil
	else
		local timer = vim.uv.new_timer()
		pane.refresh_timer = timer
		timer:start(
			5000,
			5000,
			vim.schedule_wrap(function()
				if pane.refresh_timer == timer and pane.selection and pane.selection.job and not pane.refreshing then
					pane.on_reload(pane.selection, { background = true })
				end
			end)
		)
	end
	M.render(pane)
end

---@param pane PullsPipelinesLogs
function M.toggle_raw(pane)
	pane.show_raw = not pane.show_raw
	M.render(pane)
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
	local pending = vim.list_extend({}, log)
	local groups = {}
	local collapse = false
	for _, entry in ipairs(log) do
		if entry.entries and pane.collapsed[entry.fold_key] == false then
			collapse = true
			break
		end
	end

	while #pending > 0 do
		local group = table.remove(pending)
		if group.entries then
			---@cast group PullsLogGroup
			groups[#groups + 1] = group
			for _, entry in ipairs(group.entries) do
				if entry.entries then
					pending[#pending + 1] = entry
				end
			end
		end
	end

	for _, group in ipairs(groups) do
		pane.collapsed[group.fold_key] = collapse
	end
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
