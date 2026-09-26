local requests = require("atlas.core.requests")
local spinner = require("atlas.ui.components.spinner")
local ui_utils = require("atlas.ui.utils")

---@class PullsPipelinesConfig
---@field buf integer
---@field win integer
---@field context PullsPipelineContext
---@field backend PullsPipelineBackend|nil
---@field selection PullsPipelinesSelection|nil
---@field file { path: string, content: string }|"loading"|string|nil
---@field requests AtlasRequestScope|nil
---@field spinner SpinnerInstance|nil
---@field on_update fun()

local M = {}

local namespace = vim.api.nvim_create_namespace("atlas.pipelines.config")

---@param pane PullsPipelinesConfig
local function stop_spinner(pane)
	if pane.spinner then
		pane.spinner:stop()
		pane.spinner = nil
	end
end

---@param pane PullsPipelinesConfig
function M.render(pane)
	local file = pane.file
	local content, path = "", "Configuration"
	if type(file) == "table" then
		content, path = file.content, file.path
	elseif type(file) == "string" and file ~= "loading" then
		content = file
	end
	local filetype = type(file) == "table" and (vim.filetype.match({ filename = path }) or "") or ""
	local lines = vim.split(content:gsub("\r\n", "\n"), "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if file == "loading" then
		for _ = 1, math.floor((vim.api.nvim_win_get_height(pane.win) - 1) / 2) do
			lines[#lines + 1] = ""
		end
		local message = pane.spinner:text("Loading configuration...")
		lines[#lines + 1] = ui_utils.center_text(message, vim.api.nvim_win_get_width(pane.win))
	end

	pcall(vim.treesitter.stop, pane.buf)
	vim.bo[pane.buf].readonly = false
	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(pane.buf, namespace, 0, -1)
	if file == "loading" then
		vim.api.nvim_buf_set_extmark(pane.buf, namespace, #lines - 1, 0, {
			end_col = #lines[#lines],
			hl_group = "AtlasTextMuted",
		})
	end
	vim.bo[pane.buf].modifiable = false
	vim.bo[pane.buf].modified = false
	vim.bo[pane.buf].readonly = true
	vim.bo[pane.buf].filetype = filetype
	vim.bo[pane.buf].syntax = filetype
	if filetype ~= "" then
		pcall(vim.treesitter.start, pane.buf, vim.treesitter.language.get_lang(filetype) or filetype)
	end
	vim.wo[pane.win].winbar = " " .. path:gsub("%%", "%%%%") .. " "
	vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
end

---@param pane PullsPipelinesConfig
function M.clear(pane)
	if pane.requests then
		pane.requests.cancel()
	end
	stop_spinner(pane)
	pane.selection = nil
	pane.file = nil
end

---@param pane PullsPipelinesConfig
---@param selection PullsPipelinesSelection
function M.show(pane, selection)
	local previous = pane.selection
	pane.selection = selection
	if previous and previous.pipeline == selection.pipeline and pane.file then
		pane.on_update()
		return
	end
	if pane.requests then
		pane.requests.cancel()
	end
	stop_spinner(pane)

	local fetch = pane.backend and pane.backend.fetch_config
	if not fetch then
		pane.file = "Configuration is not available for this provider"
		M.render(pane)
		pane.on_update()
		return
	end

	pane.file = "loading"
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
	pane.on_update()
	loading_spinner:start()
	pane.requests = requests.new()
	pane.requests.run(function(done)
		return fetch(pane.context, selection.pipeline, done)
	end, function(file, err)
		stop_spinner(pane)
		pane.file = err or file or "Configuration is not available"
		M.render(pane)
		pane.on_update()
	end)
end

return M
