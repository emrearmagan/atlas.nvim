local notify = require("atlas.core.notify")
local action_runner = require("atlas.core.actions")
local config = require("atlas.pulls.pipelines.ui.config")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local keymaps = require("atlas.pulls.pipelines.ui.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")
local overview = require("atlas.pulls.pipelines.ui.overview")
local icons = require("atlas.ui.shared.icons")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local statusline = require("atlas.ui.statusline")
local components = require("atlas.ui.statusline.components")
local utils = require("atlas.ui.shared.utils")

---@class PullsPipelinesSession
---@field tab integer
---@field closed boolean
---@field group integer|nil
---@field explorer PullsPipelinesExplorer
---@field logs PullsPipelinesLogs
---@field overview PullsPipelinesOverview
---@field config PullsPipelinesConfig
---@field statusline AtlasStatusline
---@field action PullsPipelineAction|nil

local M = {}

---@param session PullsPipelinesSession
---@return AtlasStatuslineLayout
local function statusline_layout(session)
	local function title(ctx)
		local context = session.explorer.context
		local target = context.target
		local text = context.repo_full_name

		if type(target) == "string" then
			text = text .. " - " .. target
		elseif ctx.pr then
			text = string.format("#%s %s", ctx.pr.id, ctx.pr.title)
		end

		return text
	end

	local function log_counts()
		local segments = {}
		for _, counter in ipairs({
			{ "error", "error", "AtlasFooterError" },
			{ "warn", "warning", "AtlasFooterWarning" },
			{ "canceled", "canceled", "AtlasFooterWarning" },
			{ "success", "successful", "AtlasFooterSuccess" },
			{ "skipped", "skipped", "AtlasFooterText" },
		}) do
			local count = session.logs.counts and session.logs.counts[counter[1]] or 0
			if count > 0 then
				local label = counter[2]
				if count > 1 and (counter[1] == "error" or counter[1] == "warn") then
					label = label .. "s"
				end
				segments[#segments + 1] = { text = count .. " " .. label, hl_group = counter[3] }
			end
		end

		return segments
	end

	local function duration()
		local job = session.logs.selection and session.logs.selection.job
		if job and job.duration then
			return icons.get("updated") .. " " .. pipeline_utils.format_duration(job.duration)
		end
	end

	local function started()
		local job = session.logs.selection and session.logs.selection.job
		local started_at = job and utils.relative_time(job.started_at) or "-"
		if started_at ~= "-" then
			return icons.get("created") .. " " .. (started_at == "now" and "just now" or started_at .. " ago")
		end
	end

	local function hints(ctx)
		return components.hints(ctx.buf, keymaps.hints(session, ctx.buf))
	end

	return { title, hints, "%=", log_counts, duration, started, components.help }
end

---@param session PullsPipelinesSession
local function update_statusline(session)
	if session.action then
		session.statusline:notify("loading", session.action.label .. "...")
	elseif session.explorer.pipelines == "loading" then
		session.statusline:notify("loading", "Loading pipelines...")
	elseif session.explorer.spinner then
		session.statusline:notify("loading", "Refreshing job...")
	elseif session.logs.refreshing then
		session.statusline:notify("loading", "Loading logs...")
	elseif session.config.file == "loading" then
		session.statusline:notify("loading", "Loading configuration...")
	else
		session.statusline:clear_notice()
	end
end

---@param session PullsPipelinesSession
---@param selection PullsPipelinesSelection|nil
local function open_actions(session, selection)
	if session.closed or session.action then
		return
	end
	if not selection or not selection.pipeline then
		notify.warn("No pipeline selected")
		return
	end

	---@type PullsPipelineActionContext
	local ctx = {
		context = session.explorer.context,
		pipeline = selection.pipeline,
		stage = selection.stage,
		job = selection.job,
	}
	local backend = session.explorer.backend
	local available = vim.tbl_filter(function(action)
		return action_runner.is_available(action, ctx)
	end, backend and backend.actions or {})

	local url = ctx.job and ctx.job.url or ctx.pipeline.url
	if url and url ~= "" then
		available[#available + 1] = {
			label = "Copy URL",
			icon = icons.get("link"),
			callback = function()
				vim.fn.setreg("+", url)
				notify.success("Copied URL", { timeout = 1200 })
			end,
		}
	end

	if #available == 0 then
		notify.warn("No pipeline actions available")
		return
	end

	local title = "Actions: " .. (ctx.job and ctx.job.name or ctx.stage and ctx.stage.name or ctx.pipeline.name)
	action_runner.select(title, available, function(action)
		if action.callback then
			action.callback()
			return
		end

		if session.closed or session.action then
			return
		end
		session.action = action
		update_statusline(session)
		action_runner.run(action, ctx, function(ok, err)
			if session.closed then
				return
			end
			if not ok then
				session.action = nil
				update_statusline(session)
				if err then
					notify.error(action.label .. " failed: " .. err)
				end
				return
			end
			vim.defer_fn(function()
				if not session.closed then
					session.action = nil
					explorer.refresh(session.explorer)
				end
			end, 1000)
		end)
	end)
end

---@param session PullsPipelinesSession
local function setup_buffers(session)
	local prefix = string.format("atlas://pipelines/%d", session.tab)
	session.explorer.buf = utils.buffer.create(prefix .. "/pipelines", "atlas-ui.pipelines")
	session.logs.buf = utils.buffer.create(prefix .. "/logs", "atlas-ui.pipeline-log")
	session.overview.buf = utils.buffer.create(prefix .. "/overview", "atlas-ui.pipeline-overview")
	session.config.buf = utils.buffer.create(prefix .. "/config", "")
	vim.bo[session.config.buf].readonly = true
	vim.bo[session.explorer.buf].bufhidden = "wipe"
end

---@param session PullsPipelinesSession
local function setup_windows(session)
	local placeholder_buf = vim.api.nvim_get_current_buf()
	session.logs.win = vim.api.nvim_get_current_win()
	session.overview.win = session.logs.win
	session.config.win = session.logs.win
	vim.api.nvim_win_set_buf(session.logs.win, session.logs.buf)
	utils.buffer.delete(placeholder_buf)
	session.explorer.win = vim.api.nvim_open_win(session.explorer.buf, true, {
		split = "left",
		win = session.logs.win,
		width = math.max(1, math.min(40, math.floor(vim.o.columns * 0.3))),
	})
	for _, pane in ipairs({ session.explorer, session.logs }) do
		for option, value in pairs({
			number = false,
			relativenumber = false,
			list = false,
			signcolumn = "no",
			foldcolumn = "0",
			statuscolumn = "",
			wrap = false,
		}) do
			vim.api.nvim_set_option_value(option, value, { win = pane.win })
		end
		session.statusline:attach(pane.win)
	end
end

---@param session PullsPipelinesSession
local function cleanup(session)
	if session.closed then
		return
	end
	session.closed = true
	explorer.dispose(session.explorer)
	logs.dispose(session.logs)
	config.clear(session.config)
	session.statusline:dispose()
	vim.api.nvim_del_augroup_by_id(session.group)
end

---@param session PullsPipelinesSession
local function close(session)
	cleanup(session)
	if utils.tab.valid(session.tab) and #vim.api.nvim_list_tabpages() > 1 then
		vim.cmd(vim.api.nvim_tabpage_get_number(session.tab) .. "tabclose")
	else
		for _, pane in ipairs({ session.explorer, session.logs }) do
			if utils.window.valid(pane.win) then
				pcall(vim.api.nvim_win_close, pane.win, true)
			end
		end
	end
	utils.buffer.delete(session.explorer.buf)
	utils.buffer.delete(session.logs.buf)
	utils.buffer.delete(session.overview.buf)
	utils.buffer.delete(session.config.buf)
end

---@param session PullsPipelinesSession
local function on_close(session)
	cleanup(session)
	vim.schedule(function()
		close(session)
	end)
end

---@param session PullsPipelinesSession
local function setup_events(session)
	session.group = vim.api.nvim_create_augroup("AtlasPipelines" .. session.tab, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = session.group,
		callback = function()
			explorer.render(session.explorer)
			logs.render(session.logs)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.group,
		pattern = { tostring(session.explorer.win), tostring(session.logs.win) },
		callback = function()
			on_close(session)
		end,
	})
	for _, pane in ipairs({ session.explorer, session.logs, session.overview, session.config }) do
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = session.group,
			buffer = pane.buf,
			callback = function()
				on_close(session)
			end,
		})
	end
end

---@param session PullsPipelinesSession
---@param buf integer
local function show_buffer(session, buf)
	vim.api.nvim_win_set_buf(session.logs.win, buf)
	session.statusline:attach(session.logs.win)
end

---@param session PullsPipelinesSession
---@param selection PullsPipelinesSelection|nil
---@param opts { force_refresh?: boolean, background?: boolean }|nil
local function show_selection(session, selection, opts)
	config.clear(session.config)
	if selection and selection.pipeline and not selection.job then
		show_buffer(session, session.overview.buf)
		logs.show(session.logs, nil)
		overview.show(session.overview, selection)
	else
		show_buffer(session, session.logs.buf)
		logs.show(session.logs, selection, opts)
	end
end

---@param session PullsPipelinesSession
---@param selection PullsPipelinesSelection|nil
local function toggle_config(session, selection)
	if utils.window.has_buffer(session.logs.win, session.config.buf) then
		show_selection(session, session.explorer.selection)
		return
	end
	if not selection or not selection.pipeline then
		notify.warn("No pipeline selected")
		return
	end
	show_buffer(session, session.config.buf)
	logs.show(session.logs, nil)
	config.show(session.config, selection)
end

---@param session PullsPipelinesSession
local function setup_panes(session)
	session.config.on_update = function()
		update_statusline(session)
	end
	logs.setup(session.logs, function()
		update_statusline(session)
	end, function(selection, opts)
		explorer.reload_job(session.explorer, selection, opts)
	end)
	explorer.setup(session.explorer, function(selection, opts)
		show_selection(session, selection, opts)
	end, function()
		update_statusline(session)
	end)
end

---@param context PullsPipelineContext
---@param backend PullsPipelineBackend|nil
---@param opts { selected_pipeline?: PullsPipeline, selected_stage?: PullsPipelineStage, selected_job?: PullsPipelineJob }|nil
function M.open(context, backend, opts)
	opts = opts or {}
	vim.cmd("tabnew")
	local session = {
		tab = vim.api.nvim_get_current_tabpage(),
		closed = false,
		explorer = { context = context, backend = backend, pipelines = "loading", line_map = {} },
		logs = { context = context, backend = backend, collapsed = {}, line_map = {}, entry_rows = {} },
		overview = { line_map = {} },
		config = { context = context, backend = backend },
	}
	---@cast session PullsPipelinesSession
	session.statusline = statusline.new({
		layout = statusline_layout(session),
		context = function(ctx)
			local target = session.explorer.context.target
			if type(target) == "table" and target.source then
				---@cast target PullRequest
				ctx.pr = target
			end

			ctx.pipeline = session.explorer.selection
		end,
	})
	setup_buffers(session)
	setup_windows(session)
	setup_events(session)
	setup_panes(session)
	keymaps.setup(session, function()
		close(session)
	end, function(selection)
		open_actions(session, selection)
	end, function(selection)
		toggle_config(session, selection)
	end)
	explorer.refresh(
		session.explorer,
		{ pipeline = opts.selected_pipeline, stage = opts.selected_stage, job = opts.selected_job }
	)
end

return M
