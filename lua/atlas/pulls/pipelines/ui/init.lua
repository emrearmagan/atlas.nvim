local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local actions = require("atlas.pulls.pipelines.ui.actions")
local config = require("atlas.pulls.pipelines.ui.config")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local keymaps = require("atlas.pulls.pipelines.ui.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")
local icons = require("atlas.ui.shared.icons")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

---@class PullsPipelinesSession
---@field tab integer
---@field closed boolean
---@field group integer|nil
---@field explorer PullsPipelinesExplorer
---@field logs PullsPipelinesLogs
---@field config PullsPipelinesConfig
---@field statusline AtlasStatusline
---@field action PullsPipelineAction|nil

local M = {}

---@param pane PullsPipelinesLogs
---@return AtlasStatuslineSegment[]
local function log_counts(pane)
	local items = {}
	local counts = pane.counts
	if not counts then
		return items
	end
	for _, counter in ipairs({
		{ "error", "error", "AtlasFooterError" },
		{ "warn", "warning", "AtlasFooterWarning" },
		{ "canceled", "canceled", "AtlasFooterWarning" },
		{ "success", "successful", "AtlasFooterSuccess" },
		{ "skipped", "skipped", "AtlasFooterText" },
	}) do
		local count = counts[counter[1]] or 0
		if count > 0 then
			local label = counter[2]
			if count > 1 and (counter[1] == "error" or counter[1] == "warn") then
				label = label .. "s"
			end
			items[#items + 1] = {
				text = count .. " " .. label,
				hl_group = counter[3],
				align = "right",
				priority = 1,
			}
		end
	end
	return items
end

---@param session PullsPipelinesSession
local function update_statusline(session)
	local context = session.explorer.context
	local target = context.target
	local title = context.repo_full_name
	if type(target) == "string" then
		title = title .. " - " .. target
	elseif target.source then
		title = string.format("#%s %s", target.id, target.title)
	end
	local heading = {
		text = title,
		hl_group = "AtlasFooterText",
		priority = 5,
		min_width = 12,
	}
	local items = vim.list_extend({ heading }, log_counts(session.logs))

	local job = session.logs.selection and session.logs.selection.job
	if job then
		if job.duration then
			local duration = job.duration < 60 and string.format("%ds", math.floor(job.duration))
				or utils.human_duration(job.duration)
			items[#items + 1] = {
				text = icons.general("updated") .. " " .. duration,
				hl_group = "AtlasFooterText",
				align = "right",
				priority = 0,
			}
		end
		local started = utils.relative_time(job.started_at)
		if started ~= "-" then
			items[#items + 1] = {
				text = icons.general("created") .. " " .. (started == "now" and "just now" or started .. " ago"),
				hl_group = "AtlasFooterText",
				align = "right",
				priority = 0,
			}
		end
	end

	session.statusline:set_items(items)
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

	local ctx = {
		context = session.explorer.context,
		pipeline = selection.pipeline,
		stage = selection.stage,
		job = selection.job,
	}
	actions.open(session.explorer.backend, ctx, function(action)
		if session.closed or session.action then
			return
		end
		session.action = action
		update_statusline(session)
		action.run(ctx, function(err)
			if session.closed then
				return
			end
			if err then
				session.action = nil
				update_statusline(session)
				notify.error(action.label .. " failed: " .. err)
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
	session.explorer.buf = utils.buffer.create(prefix .. "/pipelines", "atlas.pipelines")
	session.logs.buf = utils.buffer.create(prefix .. "/logs", "atlas.pipeline-log")
	session.config.buf = utils.buffer.create(prefix .. "/config", "")
	vim.bo[session.config.buf].readonly = true
	vim.bo[session.explorer.buf].bufhidden = "wipe"
end

---@param session PullsPipelinesSession
local function setup_windows(session)
	local placeholder_buf = vim.api.nvim_get_current_buf()
	session.logs.win = vim.api.nvim_get_current_win()
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
	for _, pane in ipairs({ session.explorer, session.logs, session.config }) do
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
		if selection and selection.pipeline and not selection.job then
			vim.api.nvim_win_set_buf(session.config.win, session.config.buf)
			logs.show(session.logs, nil)
			config.show(session.config, selection)
		else
			config.clear(session.config)
			vim.api.nvim_win_set_buf(session.logs.win, session.logs.buf)
			logs.show(session.logs, selection, opts)
		end
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
		statusline = statusline.new({ help_key = (resolver.resolve("ui.help") or {})[1] }),
		explorer = { context = context, backend = backend, pipelines = "loading", line_map = {} },
		logs = { context = context, backend = backend, collapsed = {}, line_map = {}, entry_rows = {} },
		config = { context = context, backend = backend },
	}
	---@cast session PullsPipelinesSession
	setup_buffers(session)
	setup_windows(session)
	setup_events(session)
	setup_panes(session)
	keymaps.setup(session, function()
		close(session)
	end, function(selection)
		open_actions(session, selection)
	end)
	explorer.refresh(
		session.explorer,
		{ pipeline = opts.selected_pipeline, stage = opts.selected_stage, job = opts.selected_job }
	)
end

return M
