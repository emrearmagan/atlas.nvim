---@alias PullsPipelinesSelection { pipeline?: PullsPipeline, stage?: PullsPipelineStage, job?: PullsPipelineJob, step?: integer }

---@class PullsPipelinesExplorer
---@field buf integer|nil
---@field win integer|nil
---@field context PullsPipelineContext
---@field backend PullsPipelineBackend|nil
---@field requests AtlasRequestScope|nil
---@field pipelines PullsPipeline[]|"loading"|string
---@field line_map table<integer, PullsPipelinesSelection>
---@field selection PullsPipelinesSelection|nil
---@field spinner SpinnerInstance|nil
---@field loading_jobs table<string, string>
---@field on_select fun(selection: PullsPipelinesSelection|nil, opts?: { force_refresh?: boolean })|nil
---@field on_update fun()|nil

local M = {}

local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local history = require("atlas.pulls.pipelines.ui.history")
local renderer = require("atlas.pulls.pipelines.ui.explorer.renderer")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

---@param pane PullsPipelinesExplorer
local function stop_spinner(pane)
	if pane.spinner then
		pane.spinner:stop()
		pane.spinner = nil
	end
	pane.loading_jobs = {}
end

---@param pane PullsPipelinesExplorer
---@param job PullsPipelineJob|nil
local function start_spinner(pane, job)
	if not pane.spinner then
		---@type SpinnerInstance
		local loading_spinner
		loading_spinner = spinner.create({
			on_tick = function(frame)
				if pane.spinner == loading_spinner then
					for id in pairs(pane.loading_jobs) do
						pane.loading_jobs[id] = frame
					end
					renderer.render_loading(pane)
				end
			end,
		})
		pane.spinner = loading_spinner
		loading_spinner:start()
	end
	pane.loading_jobs = job and { [job.id] = pane.spinner:current_frame() } or {}
	M.render(pane)
end

---@param pane PullsPipelinesExplorer
---@return PullsPipelinesSelection|nil
function M.current_selection(pane)
	local win = pane.win
	if not win or not utils.window.valid(win) then
		return nil
	end

	local row = vim.api.nvim_win_get_cursor(win)[1]
	return pane.line_map[row]
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
local function show_selection(pane, selection)
	local previous_job = pane.selection and pane.selection.job
	local job = selection and selection.job
	pane.selection = selection
	if job and job ~= previous_job and pane.backend and pane.backend.fetch_job then
		M.reload_job(pane, selection)
		return
	end

	if not job and next(pane.loading_jobs) then
		pane.requests.cancel()
		stop_spinner(pane)
	end
	M.render(pane, selection)
	if pane.on_select then
		pane.on_select(selection)
	end
end

---@param pane PullsPipelinesExplorer
function M.select(pane)
	local selection = M.current_selection(pane)
	if selection and selection.pipeline then
		show_selection(pane, selection)
	end
end

---@param pane PullsPipelinesExplorer
---@param direction 1|-1
---@param selection PullsPipelinesSelection|nil
function M.navigate_job(pane, direction, selection)
	if not utils.window.valid(pane.win) then
		return
	end
	local row = selection and renderer.find_selection(pane, selection) or vim.api.nvim_win_get_cursor(pane.win)[1]
	local current_job = selection and selection.job
	local boundary = direction > 0 and vim.api.nvim_buf_line_count(pane.buf) or 1
	for target = row + direction, boundary, direction do
		local entry = pane.line_map[target]
		if entry and entry.job and not entry.step and entry.job ~= current_job then
			vim.api.nvim_win_set_cursor(pane.win, { target, 0 })
			show_selection(pane, entry)
			return
		end
	end
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
function M.reload_job(pane, selection)
	selection = selection or M.current_selection(pane)
	local current = selection and selection.job
	if not selection or not selection.pipeline or not current then
		return
	end
	local fetch = pane.backend and pane.backend.fetch_job
	if pane.requests then
		pane.requests.cancel()
	end
	pane.requests = requests.new()
	start_spinner(pane, current)
	if pane.on_update then
		pane.on_update()
	end
	if pane.selection and pane.selection.job == current and pane.on_select then
		pane.on_select(pane.selection, { force_refresh = true })
	end

	pane.requests.run(function(done)
		if fetch then
			return fetch(pane.context, selection.pipeline, current, done)
		end
		done(current, nil)
	end, function(job, err)
		stop_spinner(pane)
		if job then
			for key in pairs(current) do
				current[key] = job[key]
			end
			for key, value in pairs(job) do
				current[key] = value
			end
		end
		M.render(pane)
		if pane.on_update then
			pane.on_update()
		end
		if err then
			notify.error("Failed to refresh job: " .. err)
		elseif pane.selection and pane.selection.job == current and pane.on_select then
			pane.on_select(pane.selection, { force_refresh = false })
		end
	end)
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
function M.render(pane, selection)
	renderer.render(pane, selection)
end

---@param pane PullsPipelinesExplorer
---@param pipelines PullsPipeline[]|nil
---@param err string|nil
local function finish_loading(pane, pipelines, err)
	stop_spinner(pane)
	pane.pipelines = err or pipelines or {}
	local target = pane.context.target
	if not err and type(target) == "table" and target.stages and pipelines and pipelines[1] then
		pane.context.target = pipelines[1]
	end
	local selection = pane.selection
	if selection then
		selection.step = nil
	end
	M.render(pane, selection)
	local row = selection and renderer.find_selection(pane, selection)
	pane.selection = nil
	show_selection(pane, row and pane.line_map[row])
	if err then
		notify.error("Failed to load pipelines: " .. err)
	end
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
function M.refresh(pane, selection)
	selection = selection or pane.selection
	pane.selection = selection and selection.pipeline and selection or nil
	if pane.requests then
		pane.requests.cancel()
	end
	pane.requests = requests.new()
	pane.pipelines = "loading"
	if pane.on_select then
		pane.on_select(nil)
	end
	start_spinner(pane)

	local backend = pane.backend
	if not backend then
		finish_loading(pane, nil, "Pipelines are not available")
		return
	end

	pane.requests.run(function(done)
		return backend.fetch(pane.context, { force_refresh = true }, done)
	end, function(pipelines, err)
		finish_loading(pane, pipelines, err)
	end)
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
function M.show_history(pane, selection)
	local pipeline = selection and selection.pipeline
	local backend = pane.backend
	if not pipeline then
		notify.warn("Select a pipeline first")
		return
	end
	if not backend or not backend.fetch_history then
		notify.warn("Build history is not available for this provider")
		return
	end

	history.open(pane.context, backend, pipeline, function(run)
		if not pane.on_select or type(pane.pipelines) ~= "table" then
			return
		end
		local pipelines = vim.list_extend({}, pane.pipelines)
		local index
		for position, current in ipairs(pipelines) do
			if current == pipeline then
				index = position
				break
			end
		end
		if not index then
			return
		end
		if pane.requests then
			pane.requests.cancel()
		end
		pane.requests = requests.new()
		pane.pipelines = "loading"
		pane.on_select(nil)
		start_spinner(pane)
		pane.requests.run(function(done)
			return backend.fetch(pane.context, { pipeline = run, force_refresh = true }, done)
		end, function(result, err)
			local loaded = result and result[1]
			if loaded then
				pipelines[index] = loaded
				pane.selection = { pipeline = loaded }
			end
			finish_loading(pane, pipelines, nil)
			if err then
				notify.error("Failed to load build: " .. err)
			end
		end)
	end)
end

---@param pane PullsPipelinesExplorer
function M.dispose(pane)
	if pane.requests then
		pane.requests.cancel()
	end
	stop_spinner(pane)
	pane.on_select = nil
	pane.on_update = nil
end

---@param pane PullsPipelinesExplorer
---@param on_select fun(selection: PullsPipelinesSelection|nil, opts?: { force_refresh?: boolean })
---@param on_update fun()
function M.setup(pane, on_select, on_update)
	pane.on_select = on_select
	pane.on_update = on_update

	vim.api.nvim_set_option_value("cursorline", true, { win = pane.win })
	vim.api.nvim_set_option_value("winfixwidth", true, { win = pane.win })
	vim.api.nvim_set_option_value("winbar", " Pipelines ", { win = pane.win })
	M.render(pane)
end

return M
